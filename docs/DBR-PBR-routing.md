# DBR / PBR 路由機制說明

> 對應 deploy 版本（`sync-googleconfig.sh` + `dbroute-*.sh` + `pbr-cust`）。
> 重點：DBR 的 table id / fwmark **不再寫死**，改由 `rt_tables` 的 `dbr_<iface>` 動態決定。
>
> 📖 **接手維護請先讀 [`MAINTAINER-GUIDE-netflix-dbr.md`](MAINTAINER-GUIDE-netflix-dbr.md)**
> （三層心智模型、設計決策 why、踩過的坑、診斷 SOP）。本文件是機制細節參考。

## 名詞定義

| 名詞 | 全稱 | 說明 |
|------|------|------|
| **DBR** | Domain-Based Routing | 依「域名」決定走哪個介面（nft + dnsmasq nftset） |
| **PBR** | Policy-Based Routing | 依「來源 IP」決定走哪個介面（ip rule） |
| **CustRule** | Custom Rule PBR | 自訂的 PBR 規則，由 `/etc/init.d/pbr-cust` 管理 |
| **OpenWrt PBR** | 系統內建 PBR 套件 | 用 nft fwmark 高位（0x00ff0000）標記，table 別名 `pbr_<iface>`（id 動態分配，會漂移） |

---

## 封包處理流程

```
封包進入路由器
       │
       ▼
┌──────────────────────────────────────────────┐
│  nft prerouting (priority -150)              │
│                                              │
│  1. domain_prerouting（DBR）                  │
│     ip daddr @route_<iface>_v4               │
│       → meta mark set <fwmark>               │
│                                              │
│     fwmark 動態決定：                          │
│       wan          → 0xfe   (table 254/main) │
│       其他 <iface> → table id 的 hex          │
│                     (DBR table 從 300 起)     │
│                                              │
│  2. mangle_prerouting → pbr_prerouting       │
│     OpenWrt PBR 套件的 fwmark（高位）          │
└──────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│  ip rule 路由決策（依 priority 順序匹配）     │
│                                              │
│  priority 100  ← DBR fwmark 規則             │
│    fwmark 0xfe   → lookup 254 (main → wan)   │
│    fwmark <hex>  → lookup <table id>         │
│      （table id = rt_tables 內 dbr_<iface>）  │
│                                              │
│  priority 200  ← CustRule PBR                │
│    from <src ip> → lookup <CustRule 數字>     │
│      table id 範圍 1000~4000                  │
│                                              │
│  priority 29995~30000 ← OpenWrt PBR 套件     │
│    fwmark 0xNN0000 → pbr_<wg iface>          │
└──────────────────────────────────────────────┘
       │
       ▼
    封包送出
```

## 優先順序

**DBR (100) > CustRule PBR (200) > Tailscale (5210~5270) > OpenWrt PBR (29987~30000)**

完整 prio 全圖（.1 實查 2026-07-12，數字越小越先評估）：

| prio | 建立者 | 內容 |
|------|--------|------|
| 0 | kernel | `lookup local`（本機位址） |
| 100 | **DBR** | `fwmark <dbr table號hex> lookup dbr_<if>`；含 wan 強制規則 `fwmark 0xfe lookup main` |
| 200 | **CustRule**（pbr-cust） | `from <src IP> lookup <CustRule編號>`（table 1000~4000） |
| 5210/5230/5250 | Tailscale | `fwmark 0x80000`：依序 main → default → **unreachable** |
| 5270 | Tailscale | `from all lookup 52`（TS 主路由表） |
| 29987 | PBR 套件 | `lookup main suppress_prefixlength 1` |
| 29988~29991 | PBR 套件 | `sport 516xx/51820 → pbr_wan`（WG 服務埠回應固定走 wan） |
| 29992~29999 | PBR 套件 | 各介面主 rule `fwmark 0xN0000/0xff0000 → pbr_<if>` |
| 30000 | PBR 套件 | uplink `fwmark 0x10000 → pbr_wan` |
| 32766/32767 | kernel | main / default（兜底） |

這代表：**即使某裝置被 CustRule 指定走 VPN，只要該域名有 DBR 設定，DBR 會優先生效。**

> ⚠️ **fwmark 0x80000 撞號地雷**：PBR 套件依介面順序分配 fwmark，第 8 個介面會拿到
> `0x80000`——與 **Tailscale 保留的 fwmark 撞號**，且 TS 的 prio 5250 `unreachable`
> 排在 PBR 套件規則之前 → 被套件標上 0x80000 的封包會先被判 unreachable。
> .1 上 wg0 正好排在這個位置（目前無害：wg0 走 CustRule，套件不會為它標記），
> **不要對排在 0x80000 位置的介面用 PBR 套件的 `interface=` 方式路由**。

### Table id / fwmark 分配（重要變更）

舊版把 fwmark/table 寫死（如 `0x105`/`0x106`、1001/1019）。**deploy 版改為動態**：

- **wan**：固定 `table 254`（main）、`fwmark 0xfe`，強制走實體 wan。
- **其他介面（wg0/wg2/wg_tw…）**：
  1. 先查 `/etc/iproute2/rt_tables` 中的 `dbr_<iface>` 取得 table id。
  2. 查不到就自動分配「目前最大 table id + 1」並寫回 `rt_tables`，**最低從 300 起**。
  3. `fwmark = printf "0x%x" <table id>`（即 table id 的十六進位）。
- **為何從 300 起**：OpenWrt PBR 套件本身用 256~261，CustRule 用 1000~4000。DBR 從 300 起，避免 PBR 套件新增介面時搶到 DBR 既有 table id 造成路由互相覆蓋。

### rt_tables 命名空間：`pbr_` vs `dbr_`（靠前綴分，不靠 id 區間）

| 前綴 | 擁有者 | 用途 / ip rule priority |
|------|--------|------------------------|
| `pbr_<iface>` | **OpenWrt PBR 套件**（`/etc/init.d/pbr`，自動產生） | 主 PBR rule，prio 29000+ |
| `dbr_<iface>` | **DBR 腳本**（`dbroute-setup.sh` / `sync-googleconfig.sh`） | DBR fwmark rule，prio 100 |

- 兩者**唯一可靠的區分是名字前綴**（`pbr_` vs `dbr_`），**不能用 table id 區間**。
- ⚠️ **table id 會漂移、會交錯**：PBR 套件用 `get_rt_tables_next_id`（= rt_tables
  目前最大 id + 1）分配，每次 reload/開機找不到自己的 `pbr_<iface>` 就用更大 id
  重建。DBR 也用「最大 id + 1」。所以 `pbr_*` 不保證落在 256~262、`dbr_*` 也不
  保證 300+——**實測重開機後 PBR 套件別名可能跑到 302~317**。任何「id ≥ 300 就是
  DBR」的判斷都是錯的，會誤把套件別名當 DBR。
- `check-pbr-wg.sh` 裡查 `pbr_<iface>`（prio≥29000，主 PBR，226/242/383/505 四處）
  與查 `dbr_<iface>`（DBR 第三階段，608）各管各的。
- **遷移（白名單制）**：`dbroute-setup.sh` 解析 DBR conf 取得介面清單後，**只把
  「DBR conf 裡確實存在的介面」**對應的舊 `pbr_<iface>` rename 成 `dbr_<iface>`
  （保留同 id，冪等）。`wan` 跳過（DBR 用 table 254）。**嚴禁用 id 區間遷移**——
  否則會誤改套件 `pbr_*` → 套件 reload 重建新 `pbr_` → 遷移再改 → 死循環 + 垃圾累積
  （此坑曾於 commit 299d469 發生，ea82c91 改白名單制修正）。

> 因此 fwmark 數值會依介面在 `rt_tables` 的登錄順序而異，**不要再背特定數值**，一律用 `ip rule show` / `cat /etc/iproute2/rt_tables` 查現值。

### 重開機會自動重建嗎？（會）

重開機後 DBR / PBR 都會自動重建，由多個開機階段分工，互有保底：

| 階段 | 觸發 | 重建內容 |
|------|------|---------|
| `S20dbroute`（init.d START=20） | 開機 | `nft -f dbroute.nft`（DBR 的 nft set + 打標 chain）；30s 後 `dbroute-refresh.sh` 填 IP。**注意：不建 ip rule** |
| `hotplug 99-pbr-cust` | 每個 `wg*`/`wan` ifup | `dbroute-setup.sh`（**遷移** + DBR ip rule prio 100 + route）；`dbroute-refresh.sh` |
| `S20pbr`（PBR 套件） | 開機 | 套件自己的 `pbr_*` 別名 + 主 PBR rule（prio 29000+） |
| `S99pbr-cust`（init.d START=99） | 開機 | CustRule（prio 200）diff 套用 |
| `rc.local` | 開機後台 | `sync-googleconfig.sh --apply`（完整 sync，重產 conf/nft + dbroute-setup，保底） |

重點：
- **DBR ip rule（prio 100）不在 S20dbroute 建，靠 wg ifup 的 hotplug 建**。
  若某 wg 介面開機時沒起來（隧道不通），它的 DBR ip rule 就不建——這是**正確
  行為**（介面沒起，建了也是黑洞），介面恢復 ifup 時自動補。
- **遷移每次跑 dbroute-setup 都會執行**（白名單制），確保舊 `pbr_<iface>` 平滑
  轉 `dbr_<iface>`，且不誤碰 PBR 套件別名。
- PBR 套件別名 id 每次開機可能不同（漂移），但因 DBR 只認名字前綴 + conf 白名單，
  兩者重開機後仍各自正確、不互踩。

> 已實機重開機驗證兩次（.8 RAX3000Z 混用機）：`dbr_wg2`/`dbr_wg4` 正確重建、
> 套件 `pbr_*` 原封不動、無 `dbr_` 孤兒、CustRule 與對外連線正常。

### 不 sync 也會重建嗎？（會，設定皆落地 flash）

各機制重開機時直接用本地已落地的設定檔重建，**不需要連 Google Sheet / 不需要 sync**：

| 機制 | 需要 sync? | 重開機做什麼 |
|------|:----------:|-------------|
| `S20dbroute` | ❌ | 用已存在的 `/etc/myscript/dbroute.nft` 載入 nft set + chain |
| `hotplug 99-pbr-cust`（wg ifup） | ❌ | 用已存在的 `dbroute-domains.conf` 跑 `dbroute-setup.sh`（含遷移 + 建 ip rule） |
| `dbroute-refresh`（cron 每分鐘） | ❌ | 刷新 nft set IP |

三類路由的設定來源與重建分工：

| 類型 | 設定存哪（flash） | 開機誰重建 | 需要 sync? |
|------|------------------|-----------|:----------:|
| DBR | `dbroute.nft` / `dbroute-domains.conf` / `rt_tables` | S20dbroute + hotplug | ❌ |
| PBR CustRule | `/etc/config/pbr`（uci） | S99pbr-cust（讀 uci） | ❌ |
| PBR 套件 | `/etc/config/pbr`（uci） | S20pbr（套件自己） | ❌ |

> `sync-googleconfig.sh` 只負責「從 Google Sheet 下載最新內容覆蓋本地檔」。停 sync
> = 本地設定停在當前版本，重開機仍用此版本重建——機制照跑，只是設定不再更新。

---

## DBR 運作細節

### 資料流

```
Google Sheet
    │  （sync-googleconfig.sh 下載解密）
    ▼
config dbroute 區塊（UCI）
    option domain    'netflix.com'
    option interface 'wg2'
    │
    │  （sync-googleconfig.sh 直接生成下列兩檔）
    ├──► /etc/dnsmasq.d/dbroute-domains.conf
    │       nftset=/netflix.com/4#inet#fw4#route_wg2_v4
    │       nftset=/myip.com.tw/4#inet#fw4#route_wan_v4
    │
    └──► /etc/myscript/dbroute.nft
            set route_wg2_v4 { type ipv4_addr; flags interval,timeout; timeout 3h; auto-merge }
            chain domain_prerouting {
                type filter hook prerouting priority -150; policy accept;
                ip daddr @route_wg2_v4 meta mark set 0x12c
                ...
            }
```

> `dbroute_satellite` 區塊（衛星節點專用）會被改寫成標準 `config dbroute` 一併處理。

### 各元件職責

| 元件 | 職責 |
|------|------|
| `sync-googleconfig.sh` | 從 Google Sheet 下載設定，**直接生成** `dbroute-domains.conf` 與 `dbroute.nft`，並載入 nft、觸發後續腳本 |
| `dbroute-domains.conf` | 告訴 dnsmasq：解析域名時把 IP 加入對應的 nft set |
| `dbroute.nft` | 定義 nft set 和 prerouting chain（打 fwmark） |
| `dbroute-setup.sh` | 建立 ip rule（fwmark → lookup table）和 ip route；priority 100 規則先清後建（**add 前先 `ip rule del` 同 key 確保冪等**，避免清除迴圈漏清時 `add` 撞 `RTNETLINK answers: File exists` 導致規則沒建成、DBR 失效），table 動態解析/自動登錄 |
| `dbroute-refresh.sh` | 透過 `nslookup ... 127.0.0.1` 重新解析所有域名，填充 nft set（cron **每分鐘**；無全域鎖、成功靜默，僅解析 0 域名時告警） |
| `dbroute-fwinclude.sh` | firewall restart/reload 時重載 `dbroute.nft`（chain 缺失時），且**每次都補跑 `dbroute-setup.sh` 自癒** DBR ip rule（見診斷陷阱） |
| `dbroute-manage.sh` | 手動管理/除錯工具（add / del / list / status / reload） |

### sync-googleconfig 觸發順序（CHANGED_DBROUTE=1 時）

1. 生成 `dbroute-domains.conf` + `dbroute.nft`（含動態 table/fwmark）
   - **介面不存在則跳過**：產生迴圈對每個非 wan 介面先 `ip link show` 檢查，
     介面不存在（打錯名 / 多機共用 Sheet 但此機無此介面）就 `continue`——
     不產 nftset/set/打標、不分配 table，並 log + 推播 `DBR_SkipMissingIface_<iface>`。
     **Why**：否則 nft 仍把封包打上孤兒 mark，但 `dbroute-setup` 因介面不在
     不建 ip rule → 封包回落 main table **靜默走 wan（洩真實 IP）**。
2. 先 `nft delete chain ... domain_prerouting` 與舊 `route_*_v4` set，再 `nft -f dbroute.nft`
3. **`dnsmasq restart`（不能用 reload）讓 nftset 綁定生效**——用 DBR 專用旗標
   `CHANGED_DBROUTE_DNS=1`，**不借用全域 `CHANGED_DHCP`**。
   **Why 必須 restart**：dnsmasq 的 nftset 綁定**只在完整 restart 時建立**，
   `reload`/SIGHUP **不重建 nftset** → 新加的 DBR 域名解析後 IP 不會進 set →
   流量不走 DBR（實測新增 myip.com.tw/whatismyipaddress 到 sheet，sync 後不轉）。
   **關於「restart 震 LAN」**：那是**舊 auto-role 把 lan 搞亂（改 IP/proto）**時才
   發生。dnsmasq init 腳本 restart 時會對 interface 發探測 `udhcpc`；lan=static 時
   只探測 wan（成功拿 lease），不影響 LAN。auto-role 移除後 lan 恆 static，
   restart 安全（實測 .7 restart → 只探測 wan，LAN 192.168.151.1 不掉）。
4. `dbroute-setup.sh`（建立 ip rule + route；add 前先 del 確保冪等）
5. `dbroute-refresh.sh`（填充 nft set IP）

### wan 介面的特殊處理

- wan 使用固定的 table 254（main 路由表）、fwmark `0xfe`
- 效果：匹配的域名強制走 wan，繞過 CustRule PBR
- 用途：某些查 IP 的網站需要顯示真實 wan IP

### nft set IP 的生命週期

1. dnsmasq 解析域名時，自動將 IP 加入 nft set
   - ⚠️ **有 AGH 的機器 client 查詢不經過 dnsmasq**（:53 被 hijack 直送 AGH:53535），
     此路徑只對「路由器本機查詢 + dbroute-refresh」有效，見「DNS 繞過防護」一節
2. nft set 設定 `timeout 3h`，IP 3 小時後自動過期
3. `dbroute-refresh.sh`（cron **每分鐘**）重新解析域名刷新
   - **Why 每分鐘**：Netflix API 域名 TTL 短（~60s）、AWS IP 池輪替，refresh 太疏
     會讓 client 從 AGH 拿到的新 IP 不在 set 內 → 該連線靜默走 wan。每分鐘 refresh
     配合 AGH `cache_ttl_min=1800` 等於持續預熱共用快取，殘餘縫隙 ≤60s

---

## DNS 繞過防護（Netflix 同戶必讀）

DBR 成立的前提是「client 的 DNS 解析路徑受控」。任何繞過受控 DNS 的路徑，都會讓
封包對應不到 set 內的 IP → 不打 mark → **靜默走預設路由**（同戶場景 = 洩真實 IP）。

### client DNS 鏈（有 AGH 的機器）

```
client :53 (UDP) ──firewall DNAT (adgh_l-a-n / adgh_v-p-n)──► AGH :53535 ──► 上游
router 本機 / dbroute-refresh ──► dnsmasq :53 ──► AGH :53535 ──► 上游
```

- **client 查詢不經過 dnsmasq**（被 hijack 直送 AGH）→ nftset 不由 client 查詢
  即時填充，只靠 `dbroute-refresh.sh`（每分鐘）經 dnsmasq 解析填入。
- refresh 與 client 共用 AGH 快取（deploy 設 `cache_ttl_min=1800`），每分鐘 refresh
  等於持續預熱 → client 拿到的 IP 幾乎必在 set 內。
- **在 dnsmasq 層做的任何過濾（如 filter_aaaa）管不到 client**——設定要下在 AGH。
- 走 TCP:53 的少數 client 會繞過 hijack 打到 dnsmasq，但 dnsmasq 上游是 AGH，
  過濾一樣生效，且 nftset 反而即時填充，無破口。

### 繞過路徑與對應防護

| 繞過路徑 | 防護 | 部署位置 |
|---------|------|---------|
| **IPv6（AAAA）**：DBR 只有 v4 set，client 走 v6 直接繞過 | 有 AGH：user_rules 對 Netflix 9 域名回 NOERROR 擋 AAAA；無 AGH：dnsmasq 全域 `filter_aaaa=1` | deploy.sh 依 AGH_BIN 自動二選一 |
| **DoT :853**（Android/Google TV「私人 DNS」） | firewall `Block-DoT`：`src='*' dest='*'` 853 REJECT（僅 forward chain）。「自動」模式裝置回落明文 :53 被 hijack 接住；「強制」模式 DNS 明壞、無靜默洩漏 | deploy.sh |
| **DoH :443**（瀏覽器） | Firefox 預設 DoH 由 AGH canary（`use-application-dns.net` → NXDOMAIN）自動停用；Chrome 自動升級不觸發（系統 DNS 是路由器 IP） | AGH 內建 |
| 手動設定 DoH 的裝置 | 無乾淨解，接受風險 | — |

- **Block-DoT 不能只擋 →wan**：被 CustRule 走 VPN 出口的裝置，DoT 從 lan→vpn
  （小寫 zone）出隧道一樣繞過。`src`/`dest` 用 `'*'` 一條蓋所有 zone 組合。
- 路由器自身的 AGH DoT 上游（tls://quad9 等）走 output chain，**不受** Block-DoT 影響。

### AAAA 擋規則（AGH user_rules，deploy.sh 自動寫入）

```
||netflix.com^$dnstype=AAAA,dnsrewrite=NOERROR
（netflix.net / nflxext.com / nflximg.net / nflximg.com / nflxso.net
 / nflxsearch.net / nflxvideo.net / netflix.com.tw 共 9 條）
```

驗證（LAN client 上）：`nslookup -type=AAAA netflix.com` 應查不到、A 記錄照常。

---

## CustRule PBR 運作細節（pbr-cust，diff 模式）

### 資料流

```
Google Sheet
    │  （sync-googleconfig 下載解密）
    ▼
config policy 區塊（UCI，/etc/config/pbr）
    option name     'CustRule1001'
    option src_addr '192.168.1.10'
    option dest_addr 'wg0'
    option enabled  '1'
    │
    │  （/etc/init.d/pbr-cust start → apply_rules diff mode）
    ▼
ip rule add prio 200 from 192.168.1.10 lookup 1001
ip route add default dev wg0 table 1001
```

### diff 模式（無感套用）

`pbr-cust` 不再每次全清重建，而是比對「應有(WANT)」與「現有(HAVE)」：

- **WANT**：從 `uci show pbr` 取所有 `CustRule*` 且 `enabled!=0` 的 `src table_id dev`。
- **HAVE**：從 `ip rule list` 取 priority 200、table 1000~4000 的現有規則。
- **要刪**：HAVE 有、WANT 沒有 → `ip rule del prio 200 ...` + flush table。
- **要加/更新**：WANT 有、HAVE 沒有 → 新增；route 的 dev 有變則重建。
- 套用後寫入 `check-pbr-wg` cache（`/tmp/check-pbr-wg/<iface>.rule` 與 `.custrules`），供 wg 介面 DOWN/UP 無感切換用。

> sync-googleconfig 中：wg 介面本身有變動才 `pbr reload`；只有 CustRule 變動則只跑 `pbr-cust start`（diff 無感）。

### 命名規則

- `CustRule` + 數字 = table ID（例如 `CustRule1001` → table 1001）
- table ID 範圍：1000~4000
- dest_addr 支援：`wan`（走 wan gateway）、`wg*`（走 WG 介面）

### 兩型介面：client-wg 型 vs CustRule-only 型（2026-07-12 釐清）

| | client-wg 型（wg3/wg_tw/wg_hk…） | CustRule-only 型（wg0/wg2） |
|---|---|---|
| 路由機制 | PBR 套件 fwmark 主 rule（prio 2999x）+ `pbr_<if>` 具名 table | **prio 200 rules + 編號 table（1001…）**，pbr-cust 維護 |
| rt_tables | 有 `pbr_<if>` 具名條目 | **沒有具名條目是常態**（如 337 缺號） |
| PBR 套件參與? | 是 | **否**——CustRule 的 uci policy 沒有 `interface` 欄位，套件把 `dest_addr='wg0'` **當域名解析**，生出 `nftset=/wg0/...` 垃圾 dnsmasq 設定（無害），並不建 fwmark 路由 |
| check-pbr-wg 健檢 | `rule_exists`（fwmark 主 rule 在不在）+ RULE_CACHE 還原 | `custrules_complete`（.custrules cache 的 prio 200 rules 齊全即健康） |

> ⚠️ **踩過的坑（commit 2ceedd8 修）**：舊版 check-pbr-wg 對 CustRule-only 型也用
> `rule_exists` 判——這型永遠沒有 fwmark 主 rule → 永遠 false → UP 冷靜期無限迴圈，
> `pingresult` 每 4 輪 3 次 `pending`（wg-status 看起來一直 pending）。**期間流量其實
> 正常走 prio 200 rules**，純誤報。同 commit 也讓 wg-status 的 `(rule缺)` 判定認得這型。
> 驗證這型路由健在：`ip rule show | grep '^200:'` + `ip route show table 1001`。

---

## 實際範例

> 範例中的 fwmark/table 數值依 `rt_tables` 實際登錄而定，以下為示意。

### 情境：Netflix 同戶（功能走 VPN、影片走 WAN）

Sheet DBR 段設定（wg2 = 通往家用出口的隧道）：

| 介面 | 域名 |
|------|------|
| wg2 | netflix.com netflix.net nflxext.com nflximg.net nflximg.com nflxso.net nflxsearch.net netflix.com.tw |
| wan | nflxvideo.net |

原理：

1. 同戶判定看 **API 流量來源 IP**（`api-global.netflix.com` 等 netflix.com 子網域）
   → 走 wg2，Netflix 看到家用出口 IP。
2. 播放時 App 經 API（走 VPN）拿 manifest，steering 依家用 IP 回覆 OCA 節點
   （`*.oca.nflxvideo.net`）→ 命中 wan 規則直連，影片大流量不佔隧道。
3. `wan nflxvideo.net` **必須明設**：若裝置被 CustRule 全走 VPN，靠 DBR fwmark
   0xfe（prio 100 < 200）才能把影片搶回 wan。
4. 需配合「DNS 繞過防護」一節（AAAA/DoT），否則 IPv6 或私人 DNS 會讓功能流量
   洩真實 IP。
5. 選配：`wan fast.com`（Netflix 測速站，打 OCA，不必走隧道）。

副作用：OCA 依家用 ISP 選節點，異地 wan 直連非最近節點，影片速度可能略遜本地。
wg 斷線時功能流量靜默回落 wan（同戶提示可能再跳）——同戶有約一個月寬限，可接受；
隧道恢復 ifup 時 hotplug 自動重建 DBR rule。

### 情境：192.168.200.3 存取 netflix.com（DBR → wg2，假設 wg2 table=300）

1. DNS 查詢 `netflix.com` → dnsmasq 將 IP 加入 `route_wg2_v4` set
2. 封包到達 prerouting → nft 匹配 `route_wg2_v4` → 打 mark `0x12c`（300）
3. ip rule priority 100：fwmark `0x12c` → lookup `300`
4. 封包走 `wg2` 出去
5. CustRule priority 200（from 192.168.200.3 → 其他 wg）**不被匹配**

### 情境：192.168.200.3 存取 myip.com.tw（DBR → wan）

1. DNS 查詢 `myip.com.tw` → dnsmasq 將 IP 加入 `route_wan_v4` set
2. 封包到達 prerouting → nft 匹配 `route_wan_v4` → 打 mark `0xfe`
3. ip rule priority 100：fwmark `0xfe` → lookup 254（main）→ 走 wan
4. CustRule priority 200 **不被匹配**

### 情境：192.168.200.3 存取 google.com（無 DBR 設定）

1. DNS 查詢 `google.com` → 不在任何 nftset 中
2. 封包到達 prerouting → nft 無匹配 → 不打 mark
3. ip rule priority 100：無 fwmark → 跳過
4. ip rule priority 200：from 192.168.200.3 → CustRule → 走對應 wg

---

## 除錯指令（Debug Cheat Sheet）

### 1. 管理工具（最常用）

```sh
# 域名路由總覽：介面狀態 / table / fwmark / 域名 / 已快取 IP 數 / ip rule / route
/etc/myscript/dbroute-manage.sh status

# 列出目前 dnsmasq 的域名→nftset 對應
/etc/myscript/dbroute-manage.sh list

# 臨時新增域名走某介面（會 restart dnsmasq）
/etc/myscript/dbroute-manage.sh add wg2 netflix.com nflxvideo.net

# 移除域名
/etc/myscript/dbroute-manage.sh del netflix.com

# 清空所有 route_*_v4 set 並 restart dnsmasq（強制重抓 IP）
/etc/myscript/dbroute-manage.sh reload
```

### 2. nft set / chain 檢查

```sh
# 列出所有 nft set
nft list sets inet fw4

# 查特定介面 set 內已快取的 IP（含 timeout）
nft list set inet fw4 route_wg2_v4

# 查 DBR 的 prerouting chain（確認 mark 規則與 priority -150）
nft list chain inet fw4 domain_prerouting

# 看某條規則命中次數（先在規則加 counter 才有數字）
nft list chain inet fw4 domain_prerouting
```

### 3. ip rule / route（路由決策層）

```sh
# 看完整 ip rule 順序（DBR=100, CustRule=200, PBR 套件=29995+）
ip rule show

# 只看 DBR 規則
ip rule show | grep "100:"

# 只看 CustRule 規則
ip rule show | grep "200:"

# 查某 table 的預設路由（table id 用 status 或 rt_tables 查得）
ip route show table 300
ip route show table 254        # wan / main

# 查 DBR table id 與介面對應（dbr_<iface>，DBR 從 300 起）
cat /etc/iproute2/rt_tables
```

### 4. 端到端驗證某 IP 走哪個介面

```sh
# 模擬從某來源 IP 連到某目的 IP，核對選用的 table / 介面
ip route get <目的IP> from <來源IP> mark <fwmark>

# 例：驗證 netflix IP（先從 set 撈一個 IP）+ DBR fwmark
ip route get 1.2.3.4 from 192.168.200.3 mark 0x12c

# 確認某域名目前解析到的 IP 有沒有進 set
nslookup netflix.com 127.0.0.1
nft list set inet fw4 route_wg2_v4 | grep -A100 elements
```

### 5. dnsmasq nftset 是否生效

```sh
# 確認 dbroute-domains.conf 內容（自動生成，勿手改）
cat /etc/dnsmasq.d/dbroute-domains.conf

# 讓 dnsmasq 重建 nftset 綁定後手動觸發一次刷新填充
# ⚠️ 必須 restart 不能 reload：nftset 綁定只在 restart 時建立,reload 不重建
#    → 新域名解析後不進 set。restart 只探測 wan(lan=static),不震 LAN。
/etc/init.d/dnsmasq restart
/etc/myscript/dbroute-refresh.sh
logread -e dbroute-refresh | tail
```

### 6. CustRule PBR（pbr-cust）

```sh
# 重新套用 CustRule（diff 模式，無感）
/etc/init.d/pbr-cust start

# 全清 CustRule（1000~4000 的 rule + route）
/etc/init.d/pbr-cust stop

# 看套用日誌
cat /tmp/pbr-cust.log

# 確認 UCI 中的 CustRule 設定
uci show pbr | grep -i custrule

# 看 wg 介面 DOWN/UP 無感切換用的 cache
ls -l /tmp/check-pbr-wg/
cat /tmp/check-pbr-wg/wg2.custrules
```

### 7. 系統日誌

```sh
# DBR 相關（dbroute / dbroute-refresh）
logread -e dbroute | tail -50

# firewall include 重載 dbroute 時的訊息
logread | grep -i dbroute

# 看 firewall restart 後 chain 是否被重載
/etc/myscript/dbroute-fwinclude.sh; nft list chain inet fw4 domain_prerouting
```

### 8. 常見問題快速定位

| 症狀 | 檢查 |
|------|------|
| 域名沒走到指定 VPN | `dbroute-manage.sh status` 看 set 有沒有 IP、ip rule 是否 MISSING |
| set 內沒有 IP | dnsmasq 是否載入 conf（`cat .../dbroute-domains.conf`）；手動 `dbroute-refresh.sh` |
| ip rule MISSING | 介面是否 UP（`ip link show wg2`）；跑 `dbroute-setup.sh` |
| fwmark/table 對不上 | `cat /etc/iproute2/rt_tables` 看 `dbr_<iface>` 實際 table id（DBR 從 300 起） |
| CustRule 沒生效 | `uci show pbr` 確認 enabled；`/etc/init.d/pbr-cust start`；看 `/tmp/pbr-cust.log` |
| wg-status 顯示一直 pending（流量卻正常） | 多半是 CustRule-only 型被舊版 rule_exists 誤判，見「兩型介面」一節；`ip rule show \| grep '^200:'` 確認路由其實健在 |
| firewall restart 後失效 | fwinclude 會自動重載 nft + 補跑 setup 自癒；沒復原看 `logread -e dbroute` |
| 域名走 IPv6 繞過 DBR | client 上 `nslookup -type=AAAA netflix.com` 應查不到（見「DNS 繞過防護」） |

### 9. 診斷陷阱（踩過的坑）

- **firewall reload 有機率清掉 prio 100 的 DBR ip rule（wg 介面仍 UP、nft chain 也在）**：
  實測觸發（2026-07-06，.1）：reload 後只剩 fwmark 0xfe，`dbr_wg2/wg4` 消失，
  Netflix 功能流量靜默回落 wan。觸發源多（check-adguard 切 adgh 規則、sync、
  deploy 都會 reload），且非每次重現，真兇未查明。
  → **自癒**：`dbroute-fwinclude.sh` 已改為每次 firewall 事件都補跑
  `dbroute-setup.sh`（冪等、毫秒級），rule 流失數秒內復原。驗證：
  `/etc/init.d/firewall reload; sleep 3; ip rule show | grep '^100:'`
  應見全部規則 + logread 出現 `setup re-run (firewall include)`。

- **`ip rule show` 顯示的是 table 別名不是數字、開頭是 `100:` 不是 `priority 100`**：
  例如 DBR 規則實際顯示為 `100:  from all fwmark 0x12e lookup dbr_wg4`
  （不是 `... lookup 302`，也不是 `priority 100`）。
  → 驗證 DBR 規則在不在，**grep `dbr_wg4` 或 `0x12e`，不要 grep `"priority 100"`**
  （後者抓不到，會誤判 DBR 失效）。`ip rule list` 與 `ip rule show` 輸出格式相同。

- **「域名沒走指定 VPN」八成是 set 沒被填 IP，不是路由壞**：
  路由層（ip rule + table + nft 打標）通常都對；破口多在「封包有沒有被打上 mark」，
  而打標靠 dnsmasq 解析時把 IP 填進 `route_<iface>_v4` set。
  dnsmasq 一旦壞掉/沒解析（例如被 `restart` 連帶弄掛），set 空 → 沒打標 → 回落 wan。
  → 先 `nft list set inet fw4 route_<iface>_v4` 看有沒有 IP；
    再用 `ip route get <IP> from <src> mark <fwmark>` 確認帶 mark 時走對介面。

- **端到端確認出口公網 IP**（最直接，不靠推論）：
  ```sh
  curl -s --interface wg4 --max-time 8 https://wtfismyip.com/text   # 經 wg4 出口的公網 IP
  curl -s --max-time 8 https://wtfismyip.com/text                   # 預設(wan)出口，對照組
  ```
  兩者不同即代表 VPN 出口正常；相同代表流量其實走了 wan。

- **同一 domain 設給多個 wg**：nft `meta mark set` 是賦值非疊加，
  `domain_prerouting` chain **最後命中的規則勝**（介面名字典序最大者，如 wg4 > wg2）。
  結果只走字典序最大的那個介面，其餘靜默失效，**不報錯**。避免重複設定。

---

## 相關檔案

| 檔案 | 路徑 | 說明 |
|------|------|------|
| sync-googleconfig | `/etc/myscript/sync-googleconfig.sh` | 從 Google Sheet 同步所有設定，生成 dbroute conf/nft 並觸發後續腳本 |
| dbroute-domains.conf | `/etc/dnsmasq.d/dbroute-domains.conf` | dnsmasq nftset 對應（動態產生） |
| dbroute.nft | `/etc/myscript/dbroute.nft` | nft set + chain 規則（動態產生，priority -150） |
| dbroute-setup.sh | `/etc/myscript/dbroute-setup.sh` | 建立 ip rule + ip route（table 動態解析/自動登錄） |
| dbroute-refresh.sh | `/etc/myscript/dbroute-refresh.sh` | 重新解析域名刷新 nft set IP（cron 每分鐘，成功靜默） |
| dbroute-fwinclude.sh | `/etc/myscript/dbroute-fwinclude.sh` | firewall include 自動重載 nft + 補跑 dbroute-setup 自癒 |
| dbroute-manage.sh | `/etc/myscript/dbroute-manage.sh` | 手動管理/除錯（add/del/list/status/reload） |
| rt_tables | `/etc/iproute2/rt_tables` | DBR table id ↔ `dbr_<iface>` 對應（DBR 從 300 起） |
| pbr-cust | `/etc/init.d/pbr-cust` | CustRule PBR 服務（diff 模式無感套用） |
| 99-pbr-cust | `/etc/hotplug.d/iface/99-pbr-cust` | WG 介面 up/down 時觸發 PBR |
