# DBR / PBR 路由機制說明

## 名詞定義

| 名詞 | 全稱 | 說明 |
|------|------|------|
| **DBR** | Domain-Based Routing | 依「域名」決定走哪個介面（nft + dnsmasq nftset） |
| **PBR** | Policy-Based Routing | 依「來源 IP」決定走哪個介面（ip rule） |
| **CustRule** | Custom Rule PBR | 自訂的 PBR 規則，由 `/etc/init.d/pbr-cust` 管理 |
| **OpenWrt PBR** | 系統內建 PBR 套件 | 用 nft fwmark 高位（0x00ff0000）標記 |

---

## 封包處理流程

```
封包進入路由器
       │
       ▼
┌──────────────────────────────────────────────┐
│  nft prerouting (priority mangle / -150)     │
│                                              │
│  1. domain_prerouting（DBR）                  │
│     - 目的 IP 在 route_wan_v4  → mark 0xfe   │
│     - 目的 IP 在 route_wg0_v4 → mark 0x105   │
│     - 目的 IP 在 route_wg2_v4 → mark 0x106   │
│                                              │
│  2. mangle_prerouting → pbr_prerouting       │
│     - OpenWrt PBR 套件的 fwmark（高位）       │
└──────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│  ip rule 路由決策（依 priority 順序匹配）     │
│                                              │
│  priority 100  ← DBR fwmark 規則             │
│    fwmark 0xfe  → lookup main（走 wan）       │
│    fwmark 0x105 → lookup pbr_wg0             │
│    fwmark 0x106 → lookup pbr_wg2             │
│                                              │
│  priority 200  ← CustRule PBR                │
│    from 192.168.1.10   → lookup 1001（wg0）   │
│    from 192.168.1.123  → lookup 1019（wg_tw） │
│    from 192.168.200.3  → lookup 1004（wg_900）│
│    ...                                       │
│                                              │
│  priority 29995~30000 ← OpenWrt PBR 套件     │
│    fwmark 0x60000 → pbr_wg0                  │
│    fwmark 0x50000 → pbr_wg_900               │
│    fwmark 0x40000 → pbr_wg_tw                │
│    ...                                       │
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

---

## DBR 運作細節

### 資料流

```
Google Sheet
    │  （sync-googleconfig 下載解密）
    ▼
config dbroute 區塊
    │
    ├──► /etc/dnsmasq.d/dbroute-domains.conf
    │       nftset=/netflix.com/4#inet#fw4#route_wg2_v4
    │       nftset=/myip.com.tw/4#inet#fw4#route_wan_v4
    │
    └──► /etc/myscript/dbroute.nft
            set route_wg2_v4 { ... }
            set route_wan_v4 { ... }
            chain domain_prerouting { mark rules }
```

### 各元件職責

| 元件 | 職責 |
|------|------|
| `sync-googleconfig-v3.3.sh` | 從 Google Sheet 下載設定，產生 `dbroute-domains.conf` 和 `dbroute.nft` |
| `dbroute-domains.conf` | 告訴 dnsmasq：解析域名時把 IP 加入對應的 nft set |
| `dbroute.nft` | 定義 nft set 和 prerouting chain（打 fwmark） |
| `dbroute-setup.sh` | 建立 ip rule（fwmark → lookup table）和 ip route |
| `dbroute-refresh.sh` | 重啟 dnsmasq 刷新 nft set 裡的 IP |
| `dbroute-fwinclude.sh` | firewall restart 時自動重載 nft 規則 |

### wan 介面的特殊處理

- wan 使用固定的 table 254（main 路由表）、fwmark `0xfe`
- 效果：匹配的域名強制走 wan，繞過 CustRule PBR
- 用途：某些查 IP 的網站需要顯示真實 wan IP

### nft set IP 的生命週期

1. dnsmasq 解析域名時，自動將 IP 加入 nft set
2. nft set 設定 `timeout 3h`，IP 3 小時後自動過期
3. `dbroute-refresh.sh`（cron 每 2 小時）重啟 dnsmasq 刷新

---

## CustRule PBR 運作細節

### 資料流

```
Google Sheet
    │  （sync-googleconfig 下載解密）
    ▼
config policy 區塊
    option name 'CustRule1001'
    option src_addr '192.168.1.10'
    option dest_addr 'wg0'
    │
    │  （/etc/init.d/pbr-cust apply）
    ▼
ip rule add from 192.168.1.10 lookup 1001 priority 200
ip route add default dev wg0 table 1001
```

### 命名規則

- `CustRule` + 數字 = table ID（例如 `CustRule1001` → table 1001）
- table ID 範圍：1000~4000
- dest_addr 支援：`wan`（走 wan gateway）、`wg*`（走 WG 介面）

---

## 實際範例

### 情境：192.168.200.3 存取 netflix.com

1. DNS 查詢 `netflix.com` → dnsmasq 將 IP 加入 `route_wg2_v4` set
2. 封包到達 prerouting → nft 匹配 `route_wg2_v4` → 打 mark `0x106`
3. ip rule priority 100：fwmark `0x106` → lookup `pbr_wg2`
4. 封包走 `wg2` 出去
5. CustRule priority 200（from 192.168.200.3 → wg_900）**不被匹配**

### 情境：192.168.200.3 存取 myip.com.tw

1. DNS 查詢 `myip.com.tw` → dnsmasq 將 IP 加入 `route_wan_v4` set
2. 封包到達 prerouting → nft 匹配 `route_wan_v4` → 打 mark `0xfe`
3. ip rule priority 100：fwmark `0xfe` → lookup main → 走 wan
4. CustRule priority 200 **不被匹配**

### 情境：192.168.200.3 存取 google.com（無 DBR 設定）

1. DNS 查詢 `google.com` → 不在任何 nftset 中
2. 封包到達 prerouting → nft 無匹配 → 不打 mark
3. ip rule priority 100：無 fwmark → 跳過
4. ip rule priority 200：from 192.168.200.3 → lookup 1004 → 走 `wg_900`

---

## 相關檔案

| 檔案 | 路徑 | 說明 |
|------|------|------|
| sync-googleconfig | `/etc/myscript/sync-googleconfig-v3.3.sh` | 從 Google Sheet 同步所有設定 |
| dbroute-domains.conf | `/etc/dnsmasq.d/dbroute-domains.conf` | dnsmasq nftset 對應（動態產生） |
| dbroute.nft | `/etc/myscript/dbroute.nft` | nft set + chain 規則（動態產生） |
| dbroute-setup.sh | `/etc/myscript/dbroute-setup.sh` | 建立 ip rule + ip route |
| dbroute-refresh.sh | `/etc/myscript/dbroute-refresh.sh` | 刷新 nft set IP |
| dbroute-fwinclude.sh | `/etc/myscript/dbroute-fwinclude.sh` | firewall include 自動載入 |
| pbr-cust | `/etc/init.d/pbr-cust` | CustRule PBR 服務 |
| 99-pbr-cust | `/etc/hotplug.d/iface/99-pbr-cust` | WG 介面 up/down 時觸發 PBR |
