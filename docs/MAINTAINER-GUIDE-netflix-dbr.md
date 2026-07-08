# 維護者指南：Netflix 同戶 / DBR / PBR 架構

> **給接手者（AI 或人）的定位文件。** 這份講「為什麼這樣設計、心智模型、踩過的坑、
> 診斷 SOP」；機制細節看 [`DBR-PBR-routing.md`](DBR-PBR-routing.md)。兩份互補，先讀這份建立全局，
> 再查那份對細節。
>
> 環境：OpenWrt + busybox ash（**不是 bash**）。多機隊（gateway/hybrid/client 混用），
> 設定由 Google Sheet 經 `sync-googleconfig.sh` 加密下發。腳本由 `sync-deploy.sh` 從
> GitHub main 拉取落地。路由器可 `ssh root@192.168.1.1`（.1 RAX3000Z 主閘道）、
> `root@192.168.1.5`（hybrid，有 AGH）、`root@100.64.0.7`（tailscale，ax3000t，需
> `-i ~/.ssh/id_ed25519_openwrt`）。

---

## 0. 一分鐘全局

**目標**：讓 Netflix「同戶（household）」驗證通過——家人在外地看 Netflix，讓 Netflix 以為
大家都在同一個家用出口 IP。

**手段**：DBR（Domain-Based Routing）把 Netflix **功能域名**（API/登入）導進 VPN 隧道走
回家用出口，**影片域名**（`nflxvideo.net`）走本地 WAN 直連省頻寬。

**成立的前提（極重要）**：DBR 只在「client 的 DNS 解析路徑受控」時成立。任何繞過受控 DNS
的路徑（IPv6、DoH、DoT、硬編碼 DNS）都會讓功能流量對應不到 nft set → 不打 mark →
**靜默走預設路由 → 洩真實 IP → 同戶失效 / 影片擋播**。**這份文件一半在講怎麼堵這些繞過。**

---

## 1. 三層心智模型（最重要，先建立這個）

封包要走對出口，需要**三件事同時成立**，缺一即靜默失敗：

```
① DNS 層：client 查詢 → 受控 DNS(dnsmasq 或 AGH) → 解析時把 IP 填進 nft set
                                                    │
② 打標層：封包過 prerouting → ip daddr @route_<iface>_v4 → meta mark set <fwmark>
                                                    │
③ 路由層：ip rule prio 100 → fwmark <hex> → lookup <table> → 出對的介面
```

- **90% 的「域名沒走對」問題出在 ①**（set 沒被填 IP），不是 ②③。②③ 通常都對。
- **① 的破口 = 繞過受控 DNS**。這就是 IPv6/DoH/DoT 的危險：它們讓 client 不問你的 DNS，
  set 永遠是空的或不同步 → 封包帶著「你沒打標的目的 IP」→ 回落預設路由。

**推論**：診斷「不能播 / 走錯」時，**先確認 client 有沒有真的問這台的 DNS**，再看路由。
反過來查（先看 ip rule）會浪費時間，因為路由層幾乎總是對的。

---

## 2. 為什麼這樣設計（設計決策的 why）

| 決策 | 為什麼 |
|------|--------|
| 功能走 VPN、`nflxvideo.net` 走 WAN | 同戶只看 **API 流量 IP**；影片是大流量，塞進隧道會爆頻寬且 OCA 選點更差。分流兼顧同戶與速度。 |
| `wan nflxvideo.net` **必須明設**，不能只是「不設」 | 若裝置被 CustRule 全走 VPN，靠 DBR fwmark `0xfe`(prio 100 < CustRule 200) 才能把影片**搶回** WAN。不設 = 影片跟著 VPN 走。 |
| table 別名用 `dbr_<iface>` 前綴 | 與 OpenWrt PBR 套件的 `pbr_<iface>` 分開。**table id 會漂移**，只能靠名字前綴 + DBR conf 白名單區分，**嚴禁用 id 區間判斷**（踩過死循環，見 §4）。 |
| DBR ip rule 在 wg **ifup 的 hotplug** 建，不在開機 S20 建 | wg 沒起來時建 rule 是黑洞。介面沒起就不建（正確），恢復 ifup 自動補。 |
| refresh cron 每分鐘（原 2h） | Netflix API 域名 TTL ~60s、AWS IP 池輪替。太疏 → client 拿到的新 IP 不在 set → 靜默走 wan。每分鐘配合 AGH `cache_ttl_min=1800` 持續預熱。 |
| AAAA 擋「依有無 AGH 二選一」 | 有 AGH：client :53 被 hijack 直送 AGH，**不經 dnsmasq** → 只能在 AGH user_rules 擋；無 AGH：client 走 dnsmasq → 用 dnsmasq `filter_aaaa`。**dnsmasq 層設定對「有 AGH」的機器管不到 client。** |
| Block-DoT 用 `src='*' dest='*'` 單條全域 | 不能只擋 →wan：被 CustRule 走 VPN 出口的裝置，DoT 從 lan→vpn(小寫 zone)出隧道照樣繞過。 |
| Block-IPv6-WAN 用 firewall 擋而非關 RA | `auto-role.sh` 主 gw 強制 `lan.ra=server`（第 ~602 行），手動關 RA 會被打回。改在 firewall 擋 v6 forward，不與 auto-role 衝突。 |

### 2.1 同戶判定的真相：連線來源 IP 為主，位置一致性為輔（澄清常見誤解）

接手時常被問「Netflix 是不是用 ECS / DNS 判定同戶」。準確認知：

- **同戶判定的主軸 = 裝置連 Netflix 時的「連線來源公網 IP」**（API/登入/播放的 TCP/TLS
  實際來自哪個出口）。這就是為什麼 DBR 把**功能流量**導進 VPN、讓 Netflix 看到家用出口 IP
  就能過同戶。**不是**看你的 DNS 怎麼解析。
- **「ECS 判定同戶」的說法不精確**：ECS（EDNS Client Subnet）是 DNS 解析階段給 CDN
  選節點用的位置提示，**它是選片源（速度）機制，不是身分驗證欄位**。Netflix 不會拿
  ECS 值當「你是不是同一戶」的判據。
- **但有一個輔助訊號是真的**：Netflix 會做多訊號交叉，其中包含「**DNS 解析看到的位置**
  vs **連線來源位置**是否一致」。若**功能流量走 VPN（家用 IP）**、而**影片/DNS 解析卻顯示
  本地位置**，兩者位置打架 → 可能觸發「代理/位置不符」偵測 → **影片擋播**（不是「同戶不過」，
  是播放被擋）。「用單一 DNS 讓解析與連線位置一致」的說法，正確核心就在這裡。

**對本架構的影響（取捨，非 bug）**：現行「功能→VPN、`nflxvideo.net`→WAN + 公共 DNS
（Quad9/Cloudflare，多不帶 ECS）」在多數情況同戶正常、影片也能播。但**若遇到影片間歇擋播**，
排查順序：先確認不是 DNS 繞過（v6/DoH，見 §4），再懷疑「位置不一致」——此時的解法是
**讓影片也走 VPN**（把 `nflxvideo.net` 從 wan 改成 wg，全部統一家用出口位置），代價是影片
吃隧道頻寬、OCA 選點變差。這是「省頻寬(影片走WAN)」與「位置一致(影片走VPN)」的取捨，
預設走前者，擋播時才換後者。**上游 DNS（DoT/DoH 到 Quad9/CF/Google）本身對同戶判定無影響**，
只影響 OCA 選點速度，可放心用。

---

## 3. 資料流與元件（速查）

```
Google Sheet ──sync-googleconfig(解密)──► config dbroute 區塊
                                              │ 直接生成兩檔
     ┌────────────────────────────────────────┴─────────────┐
     ▼                                                        ▼
/etc/dnsmasq.d/dbroute-domains.conf              /etc/myscript/dbroute.nft
  nftset=/netflix.com/4#..#route_wg2_v4            set route_wg2_v4 {...}
  nftset=/nflxvideo.net/4#..#route_wan_v4          chain domain_prerouting { ip daddr @.. mark }
     │                                                        │
     ▼ dnsmasq 解析域名時填 IP 進 set              ▼ nft -f 載入
     └──────────────► dbroute-setup.sh: 建 ip rule(prio100) + route ◄──────────┘
                       dbroute-refresh.sh: cron 每分鐘重解析填 set
```

| 元件 | 職責 | 觸發 |
|------|------|------|
| `sync-googleconfig.sh` | 下載解密 Sheet，生成 conf/nft，觸發 setup/refresh | rc.local / cron / 手動 |
| `dbroute-setup.sh` | 建 ip rule(fwmark→table) + route；**冪等**(add 前先 del) | wg ifup hotplug / sync / fwinclude |
| `dbroute-refresh.sh` | nslookup 重解析填 set；每分鐘、**無鎖、成功靜默** | cron 每分鐘 |
| `dbroute-fwinclude.sh` | firewall 事件重載 nft + **補跑 setup 自癒** | 每次 firewall restart/reload |
| `dbroute-manage.sh` | 手動 add/del/list/status/reload | 人工 |

---

## 4. 踩過的坑（血淚，附 commit）

> 這節是本文件的核心。改東西前先確認不會重蹈這些坑。

### DBR / 路由

- **firewall reload 會隨機清掉 prio 100 的 DBR ip rule**（wg 仍 UP、nft chain 也在）→ 功能
  流量靜默回落 wan。觸發源多（check-adguard 切 adgh、sync、deploy 都會 reload），非每次重現，
  真兇未查明。**自癒**：`dbroute-fwinclude.sh` 每次 firewall 事件補跑 `dbroute-setup.sh`（`6b706bf`）。
  改 fwinclude 時**別把這個補跑拿掉**。
- **DBR table 別名 id 會漂移**，PBR 套件的 `pbr_*` 重開機可能跑到 300+，**任何「id≥300 就是 DBR」
  的判斷都是錯的**。用 id 區間遷移曾造成「改到套件別名→套件 reload 重建→再改→死循環」
  （`299d469` 埋雷，`ea82c91` 改白名單制修正）。**只認名字前綴 + DBR conf 白名單。**
- **dnsmasq nftset 綁定只在完整 `restart` 建立，`reload`/SIGHUP 不重建** → 新增 DBR 域名解析後
  IP 不進 set → 不轉。DBR 段必須用 `dnsmasq restart`，用專用旗標 `CHANGED_DBROUTE_DNS`
  不借用 `CHANGED_DHCP`（`3c30e7f`）。
- **介面暫時 down 時 DBR 被跳過不恢復**：介面防呆改用 `uci` 判斷而非 `ip link`（`2eb3fc5`）。
- **ip rule 清除迴圈漏清 → add 撞 "File exists" → 規則沒建成 DBR 失效**：add 前先
  `ip rule del` 同 key 確保冪等（`eb3daa2`）。清除用 `fwmark` 刪（不解析 lookup 後的 table 名，
  因為現在是別名）。
- **同一 domain 設給多個 wg**：`nft meta mark set` 是賦值非疊加，chain 最後命中的規則勝
  （介面名字典序最大者，如 wg4>wg2）。其餘靜默失效不報錯。**避免重複設定。**
- **介面不存在卻仍打 mark → 封包回落 main 靜默走 wan（洩 IP）**：生成 nft 前先 `ip link show`
  檢查，不存在就 skip 不打標並推播 `DBR_SkipMissingIface`。

### DNS 繞過（同戶的主戰場）

> ⚠️ **2026-07-07 重大修正**：原本用 **Block-DoT(853)** + **Block-IPv6-WAN(forward v6→wan)**
> 硬擋,實測**害 Netflix App(AppleTV/手機/平板)主頁圖不出、影片轉圈不播**——Netflix 裝置
> 需要 DoT/IPv6 正常運作。**兩條已移除,勿再加**(`9322ec0`)。正解改用下面的
> `Block-LAN-IPv6-ToRouter`(只擋 v6 DNS 到路由器,不擋 v6 上網)。

- **核心策略**：**不做 v6 DBR**(工程大又脆弱)。改用「逼 client DNS 走 v4」:
  v6 DNS 到路由器被擋 + AAAA 被擋 → client 只能用 v4 問 DNS(被 :53 hijack → AGH)→
  Netflix 功能域名全走 v4 → 現有 v4 DBR 接住 → 走 VPN → 同戶成立。**client 的 v6
  一般上網不擋** → Netflix App 需要的 v6 正常 → App 不壞。
- **✅ 正確規則 `Block-LAN-IPv6-ToRouter`**(input lan → 此裝置, family ipv6, tcp+udp, REJECT):
  只擋「client 用 IPv6 連路由器本身的服務(尤其 :53 v6 DNS)」,逼 DNS 走 v4。
  **關鍵:input 方向(到路由器),不是 forward(出網)**——所以不影響 client v6 上網。
- **❌ 踩過的坑(勿重蹈)**:
  - `Block-DoT`(853 REJECT forward):擋 DoT → AppleTV/手機 Netflix 圖不出/影片不播。移除。
  - `Block-IPv6-WAN`(forward lan→wan v6 REJECT):擋 client v6 出網 → 太廣,同樣害 App。移除。
- **DoH(443)繞過**:無法靠防火牆乾淨擋(藏在 HTTPS)。**真兇實例**:平板自己開了 Private DNS
  (DoH 到 Google/Cloudflare)→ 繞過 :53 hijack → 功能流量沒進 DBR → 圖出不來。
  **解法:使用者自行關 Private DNS**(Android 設定→網路→私人 DNS→關閉/自動)。Firefox 預設
  DoH 由 AGH canary(`use-application-dns.net`→NXDOMAIN)自動停用;Chrome 自動升級不觸發。
- **診斷陷阱**:①查 client v6 要在它**在線時**查(離線時 neigh 只剩過期 ULA `fd6d:`,誤判沒 v6)。
  ②client conntrack 若「有連一堆 Google IP(142.250/216.239/108.177)但 dport=53 查詢=0」→
  它在用 **v4 DoH**(那些是 dns.google),不是問你的 DNS。③平板 IP 會變(DHCP/MAC 隨機化),
  抓流量前先從 dhcp.leases 確認當下 IP。
- **filter_aaaa 對「有 AGH」機器無效**：client :53 被 hijack 到 AGH，不經 dnsmasq
  （`19c9cc3` 的自動二選一就是為此）。

### sync / 推播 / 其他

- **`--only` 曾繞過全域 md5，每次強抓完整 payload 逐段比對**；改為受全域 md5 控管，全域未變即
  早退（`706ed46`）。要無條件重套用 `--only <段> --force`。
- **LINE Notify 已於 2025-03-31 停服**，push-notify 遷 Messaging API（`c170b68`）。pushkey 內容
  格式自動分流：`PD`=PushDeer、`U/C/R+32hex`=LINE userId(需 `.secrets/line.token`)。
- **busybox 沒有 `paste`**：用 `tr`/`sed` 替代（`6626ed2`）。寫腳本前記得這裡是 ash 不是 bash。

---

## 5. Netflix 同戶完整防護清單（部署一台時逐項確認）

| # | 防護 | 有 AGH 機器 | 無 AGH 機器 | 部署位置 |
|---|------|------------|------------|---------|
| 1 | DBR 域名分流 | 功能→wg / nflxvideo→wan（同） | 同 | Sheet + sync |
| 2 | AAAA 擋 | AGH user_rules 9 域名 | dnsmasq `filter_aaaa=1` | deploy.sh 依 AGH_BIN 自動二選一(`19c9cc3`) |
| 3 | v6 DNS 擋 | **Block-LAN-IPv6-ToRouter**(input lan→此裝置 v6 REJECT) | 同 | deploy.sh |
| 4 | DBR rule 自癒 | fwinclude 補跑 setup | 同 | 腳本(`6b706bf`) |
| — | ~~DoT 擋 / IPv6 出網擋~~ | ❌ **已移除**(害 App,見 §4) | — | — |

> **注意**：#2#3 是 **deploy.sh** 裡的，`sync-deploy.sh` 只同步 `etc/myscript`，**不含
> deploy.sh**。所以「只跑 sync-deploy」的機器不會自動有這些 firewall 規則——需重跑 deploy.sh，
> 或手動下對應 uci。這是最常見的「某台沒防護」原因。
> **RAM overlay 機器手動改 uci 後,必須跑 `sync-ram2flash.sh` 落地,否則重開機掉。**

Block-LAN-IPv6-ToRouter 立即套用（冪等，只擋 v6 DNS 到路由器，不擋 v6 上網）：
```sh
uci show firewall | grep -q "name='Block-LAN-IPv6-ToRouter'" || {
  uci add firewall rule; uci set firewall.@rule[-1].name='Block-LAN-IPv6-ToRouter'
  uci set firewall.@rule[-1].src='lan'; uci set firewall.@rule[-1].proto='tcp udp'
  uci set firewall.@rule[-1].family='ipv6'; uci set firewall.@rule[-1].target='REJECT'
  uci commit firewall; /etc/init.d/firewall reload; }
/etc/myscript/sync-ram2flash.sh   # RAM overlay 機器要落地
```

---

## 6. 診斷 SOP（照順序，別跳步）

### Step 0：確認你查的是對的 client
- **client 必須在線、在該台的網、且正在用 Netflix**，否則 conntrack/neigh 抓不到即時流量，
  誤判成「沒問題/沒 v6」。
- 分清 client 是 **br-lan（家裡直連，192.168.x.x）** 還是 **wg peer（在外撥回，200 網段）**——
  兩者路徑完全不同。撥回的 peer 走 VPN 進來、無本地 v6，跟直連情境不能混。

### Step 1：先看 DNS 層（①），這裡最常壞
```sh
IP=<client_ip>
# client 有沒有問這台的 DNS？(空 = 它在用 DoH/DoT/自帶 DNS 繞過!)
grep "src=$IP " /proc/net/nf_conntrack | grep -E 'dport=53 |dport=853'
# client 有沒有公網 v6？(要 client 在線才準)
MAC=$(grep "$IP" /tmp/dhcp.leases | awk '{print $2}')
ip -6 neigh show | grep -i "$MAC" | grep 2407   # 有 2407 = 有公網 v6
# 有 AGH：測 AGH 對 netflix AAAA(應空) 與 A(應有 IP)
nslookup -port=53535 -type=AAAA netflix.com 127.0.0.1
```

### Step 2：看 set 有沒有被填 IP（①的產物）
```sh
for s in $(nft list sets inet fw4 | grep -o 'route_[a-z0-9]*_v4'); do
  echo "$s: $(nft list set inet fw4 $s | grep -c expires) IPs"; done
# client 連的 Netflix IP 在哪個 set？
nft list set inet fw4 route_wg2_v4 | grep -F <netflix_ip>   # 在=走VPN
nft list set inet fw4 route_wan_v4 | grep -F <netflix_ip>   # 在=走WAN
```

### Step 3：路由層驗證（②③，用模擬 client 來源，別在路由器上直接 curl/traceroute）
```sh
# ⚠️ 路由器自身流量走 output chain,不過 prerouting,不會被打 mark → 在路由器上測永遠走 wan,測了白測
ip route get <netflix_ip> from <client_ip> mark 0x12c   # 帶 DBR mark，應 dev wg2
ip rule show | grep '^100:'                              # DBR 規則(顯示 dbr_wg2 別名不是數字)
```

### Step 4：防護盤點
```sh
for r in Block-DoT Block-IPv6-WAN; do echo "$r: $(uci show firewall|grep -c "name='$r'")"; done
echo "filter_aaaa: $(uci -q get dhcp.@dnsmasq[0].filter_aaaa)"
echo "AGH AAAA: $(grep -c dnstype=AAAA /etc/adguardhome/adguardhome.yaml 2>/dev/null)"
```

### 「不能播 / 洩 IP」決策樹
```
client 有問這台 DNS(53)?
  否 → 用 DoH/DoT 繞過 → 查 443 目的有無 1.1.1.1/8.8.8.8/dns.google
                          → 查 Android「私人 DNS」設定(最快)；補 Block-DoT
  是 → client 有公網 v6(2407)?
        是 → v6 繞過 → 套 Block-IPv6-WAN(§5)
        否 → set 有填該 IP?
              否 → dnsmasq restart + dbroute-refresh；查介面 UP
              是 → ip route get 帶 mark 走對介面? 否→ dbroute-setup.sh 重建 rule
```

---

## 7. 常用維運

```sh
# 部署最新腳本到某台(不含 deploy.sh 的 firewall 規則!)
ssh root@192.168.1.1 "/etc/myscript/sync-deploy.sh"

# 手動 sync(Sheet 變了才有效;--force 強制重套;--only <段> 部分)
/etc/myscript/sync-googleconfig.sh --apply [--force] [--only dbroute]

# DBR 總覽
/etc/myscript/dbroute-manage.sh status

# 遠端維運指令(LineCMD)：Sheet「LineCMD」分頁填 action(白名單在 linecmd-handler.sh)
#   狀態欄「等待執行」→ sync 讀到執行 → GAS 改「已下發」防重複
#   ⚠️ 多機隊只第一台收到(狀態欄被第一台改掉)

# 推播測試
ssh root@192.168.1.1 ". /etc/myscript/push-notify.inc; PUSH_NAMES=admin; push_notify '測試'"
```

---

## 8. 給 AI 接手者的提醒

- **這裡是 busybox ash，不是 bash**。沒有 `paste`、`[[ ]]`、陣列、`${arr[@]}`。`while|read`
  在 subshell 會吞變數（LineCMD 那段用 awk 壓成單行 + 主殼 read 繞開，別退回 `while|read` 賦值）。
- **改 firewall/DBR 前先讀 §4**，很多「顯而易見的簡化」正是踩過的坑（如 id 區間、reload 取代
  restart、只擋 →wan）。
- **改動後一律**：`bash -n` 語法檢查 → commit(`type(scope): 中文摘要` + body 講 why) → push →
  `sync-deploy.sh` 到相關機器 → 有 firewall 規則的另外手動 uci(sync-deploy 不帶 deploy.sh)。
- **診斷時 client 必須在線**，且分清 br-lan 直連 vs wg peer 撥回，否則會像本文件記錄的那樣
  反覆誤判 v6。
- **auto-role.sh(55KB) 會覆蓋 lan 的 ra/dhcpv6/dhcp_option**，想改 client 網路行為前先 grep
  它有沒有在管那個 uci 鍵，否則手動改會被打回。
- 相關記憶：`memory/netflix-dbr-design.md`、`linecmd-remote-action.md`、
  `line-push-migration.md`、`openwrt-deploy-repo-layout.md`。
