# DBR / PBR 路由機制說明

> 對應 deploy 版本（`sync-googleconfig.sh` + `dbroute-*.sh` + `pbr-cust`）。
> 重點：DBR 的 table id / fwmark **不再寫死**，改由 `rt_tables` 的 `pbr_<iface>` 動態決定。

## 名詞定義

| 名詞 | 全稱 | 說明 |
|------|------|------|
| **DBR** | Domain-Based Routing | 依「域名」決定走哪個介面（nft + dnsmasq nftset） |
| **PBR** | Policy-Based Routing | 依「來源 IP」決定走哪個介面（ip rule） |
| **CustRule** | Custom Rule PBR | 自訂的 PBR 規則，由 `/etc/init.d/pbr-cust` 管理 |
| **OpenWrt PBR** | 系統內建 PBR 套件 | 用 nft fwmark 高位（0x00ff0000）標記，table 256~261 |

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
│      （table id = rt_tables 內 pbr_<iface>）  │
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

**DBR (100) > CustRule PBR (200) > OpenWrt PBR (29995+)**

- DBR 的 fwmark 規則在 priority 100，最先被檢查
- CustRule 的 from 規則在 priority 200，次之
- OpenWrt PBR 套件在 priority 29995+，最後

這代表：**即使某裝置被 CustRule 指定走 VPN，只要該域名有 DBR 設定，DBR 會優先生效。**

### Table id / fwmark 分配（重要變更）

舊版把 fwmark/table 寫死（如 `0x105`/`0x106`、1001/1019）。**deploy 版改為動態**：

- **wan**：固定 `table 254`（main）、`fwmark 0xfe`，強制走實體 wan。
- **其他介面（wg0/wg2/wg_tw…）**：
  1. 先查 `/etc/iproute2/rt_tables` 中的 `pbr_<iface>` 取得 table id。
  2. 查不到就自動分配「目前最大 table id + 1」並寫回 `rt_tables`，**最低從 300 起**。
  3. `fwmark = printf "0x%x" <table id>`（即 table id 的十六進位）。
- **為何從 300 起**：OpenWrt PBR 套件本身用 256~261，CustRule 用 1000~4000。DBR 從 300 起，避免 PBR 套件新增介面時搶到 DBR 既有 table id 造成路由互相覆蓋。

> 因此 fwmark 數值會依介面在 `rt_tables` 的登錄順序而異，**不要再背特定數值**，一律用 `ip rule show` / `cat /etc/iproute2/rt_tables` 查現值。

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
| `dbroute-setup.sh` | 建立 ip rule（fwmark → lookup table）和 ip route；priority 100 規則先清後建，table 動態解析/自動登錄 |
| `dbroute-refresh.sh` | 透過 `nslookup ... 127.0.0.1` 重新解析所有域名，填充 nft set（cron 定時 + 全域鎖） |
| `dbroute-fwinclude.sh` | firewall restart/reload 時，若 chain 不存在則重載 `dbroute.nft` 並排程刷新 |
| `dbroute-manage.sh` | 手動管理/除錯工具（add / del / list / status / reload） |

### sync-googleconfig 觸發順序（CHANGED_DBROUTE=1 時）

1. 生成 `dbroute-domains.conf` + `dbroute.nft`（含動態 table/fwmark）
2. 先 `nft delete chain ... domain_prerouting` 與舊 `route_*_v4` set，再 `nft -f dbroute.nft`
3. 標記 `CHANGED_DHCP=1` → 重啟 dnsmasq 讓 nftset 生效
4. `dbroute-setup.sh`（建立 ip rule + route）
5. `dbroute-refresh.sh`（填充 nft set IP）

### wan 介面的特殊處理

- wan 使用固定的 table 254（main 路由表）、fwmark `0xfe`
- 效果：匹配的域名強制走 wan，繞過 CustRule PBR
- 用途：某些查 IP 的網站需要顯示真實 wan IP

### nft set IP 的生命週期

1. dnsmasq 解析域名時，自動將 IP 加入 nft set
2. nft set 設定 `timeout 3h`，IP 3 小時後自動過期
3. `dbroute-refresh.sh`（cron）重新解析域名刷新

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
- 套用後寫入 `check-pbr-wg` cache（`/tmp/check-pbr-wg.<iface>.rule` 與 `.custrules`），供 wg 介面 DOWN/UP 無感切換用。

> sync-googleconfig 中：wg 介面本身有變動才 `pbr reload`；只有 CustRule 變動則只跑 `pbr-cust start`（diff 無感）。

### 命名規則

- `CustRule` + 數字 = table ID（例如 `CustRule1001` → table 1001）
- table ID 範圍：1000~4000
- dest_addr 支援：`wan`（走 wan gateway）、`wg*`（走 WG 介面）

---

## 實際範例

> 範例中的 fwmark/table 數值依 `rt_tables` 實際登錄而定，以下為示意。

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

# 查 DBR table id 與介面對應（pbr_<iface>，DBR 從 300 起）
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

# 重啟 dnsmasq 後手動觸發一次刷新填充
service dnsmasq restart
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
ls -l /tmp/check-pbr-wg.*
cat /tmp/check-pbr-wg.wg2.custrules
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
| fwmark/table 對不上 | `cat /etc/iproute2/rt_tables` 看 `pbr_<iface>` 實際 table id（DBR 從 300 起） |
| CustRule 沒生效 | `uci show pbr` 確認 enabled；`/etc/init.d/pbr-cust start`；看 `/tmp/pbr-cust.log` |
| firewall restart 後失效 | 確認 `dbroute-fwinclude.sh` 有被 firewall include 觸發重載 |

---

## 相關檔案

| 檔案 | 路徑 | 說明 |
|------|------|------|
| sync-googleconfig | `/etc/myscript/sync-googleconfig.sh` | 從 Google Sheet 同步所有設定，生成 dbroute conf/nft 並觸發後續腳本 |
| dbroute-domains.conf | `/etc/dnsmasq.d/dbroute-domains.conf` | dnsmasq nftset 對應（動態產生） |
| dbroute.nft | `/etc/myscript/dbroute.nft` | nft set + chain 規則（動態產生，priority -150） |
| dbroute-setup.sh | `/etc/myscript/dbroute-setup.sh` | 建立 ip rule + ip route（table 動態解析/自動登錄） |
| dbroute-refresh.sh | `/etc/myscript/dbroute-refresh.sh` | 重新解析域名刷新 nft set IP |
| dbroute-fwinclude.sh | `/etc/myscript/dbroute-fwinclude.sh` | firewall include 自動重載 nft |
| dbroute-manage.sh | `/etc/myscript/dbroute-manage.sh` | 手動管理/除錯（add/del/list/status/reload） |
| rt_tables | `/etc/iproute2/rt_tables` | DBR table id ↔ `pbr_<iface>` 對應（DBR 從 300 起） |
| pbr-cust | `/etc/init.d/pbr-cust` | CustRule PBR 服務（diff 模式無感套用） |
| 99-pbr-cust | `/etc/hotplug.d/iface/99-pbr-cust` | WG 介面 up/down 時觸發 PBR |
