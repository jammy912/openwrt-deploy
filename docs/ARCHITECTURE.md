# 系統架構總覽

> 這套系統 = **OpenWrt 多機隊** + **Google Sheet 集中設定** + **tailscale/headscale VPN**
> + **自動角色切換**。這份是頂層地圖:先看懂整體怎麼組合,再查各子系統的細節 doc（見文末表）。

---

## 1. 三個核心設計

| 設計 | 一句話 | 為什麼 |
|------|--------|--------|
| **設定集中在 Google Sheet** | 所有機器的網路/DHCP/PBR/QoS/DBR/推播設定都在一份加密 Sheet | 一處改、全機隊同步;不用逐台 SSH 改設定 |
| **腳本集中在 GitHub** | `/etc/myscript/*` 由 `sync-deploy.sh` 從 GitHub main 拉取 | 邏輯改一次、push、各機 sync-deploy 落地 |
| **角色動態切換** | 每台開機/WAN 變化時 `auto-role.sh` 自動決定當 gateway/client | 同一份設定,插哪台當主閘道都行;主機掛了副機頂上 |

**兩條「集中→分發」的線**（別搞混）：
- **設定**：Google Sheet → `sync-googleconfig.sh`（解密）→ 各機的 `/etc/config`
- **腳本**：GitHub → `sync-deploy.sh`（拉取）→ 各機的 `/etc/myscript`

---

## 2. 機器角色（auto-role 動態決定）

```
                    ┌─────────────────────────────────┐
                    │   auto-role.sh 每台自己判斷       │
                    │  (rc.local 開機 / WAN hotplug /   │
                    │   cron 定時 觸發)                 │
                    └─────────────────────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
   有 WAN + 最高優先          有 WAN + 非最高優先          沒 WAN
   ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
   │  主 gateway   │          │  副 gateway   │          │   client     │
   │ IP=.1         │          │ 靜態 IP       │          │ 靜態 IP       │
   │ DHCP server 開 │          │ DHCP 關        │          │ DHCP 關        │
   │ gw_mode=server │          │ gw_mode=server │          │ gw_mode=client │
   └──────────────┘          └──────────────┘          └──────────────┘
```

- 優先權由 Sheet 下發的 `.mesh_priority`（數字大=優先當主）決定。
- **主 gateway 掛了 → 副 gateway 自動頂上**（重新選主）。這就是為什麼設定要能「插哪台都行」。
- mesh 互連：無線 mesh（`.mesh_wireless`）/ 有線 mesh（`.mesh_wired`）+ batman-adv + tailscale。
- 詳見 [auto-role.md]（待補）。

---

## 3. 開機流程（rc.local 串連全局）

```
開機
 │
 ├─ rc.local: /etc/config → 複製到 /tmp/config_ram → mount --bind（★RAM overlay）
 │            /etc/crontabs 同樣掛 RAM。有 USB 機型跑 agh-usb-init（AGH work-dir→RAM）
 │            ★ 因此手動改 uci 要 sync-ram2flash 落地（見 ram-overlay-sync-flash.md）
 │
 ├─ S20dbroute: 載入 dbroute.nft（DBR set + 打標 chain）
 ├─ S20pbr / S99pbr-cust: PBR 套件 + CustRule
 ├─ auto-role.sh: 決定角色 + 套 IP/DHCP/頻道政策
 ├─ hotplug (wg ifup): dbroute-setup（建 DBR ip rule）
 └─ rc.local 後台: sync-googleconfig --apply（完整 sync,保底重建所有設定）
```

重點：**設定皆落地 flash,重開機不靠 sync 也能重建**（各機制用本地已存的設定檔）。
sync 只負責「從 Sheet 拉最新覆蓋本地」。

---

## 4. 設定同步鏈（Google Sheet → 機器）

```
Google Sheet（多個分頁：Network/DHCP/PBR/QoS/Crontab/DBR/PushKey/LineCMD...）
   │  GAS（Apps Script）輸出 → AES 加密 → base64
   ▼
sync-googleconfig.sh（每分鐘 cron / rc.local / 手動）
   │  下載 → 解密 → 全域 md5 比對（沒變早退）→ 格式驗證 → 分段解析
   ▼
各段落套用：
   config interface/wireguard → /etc/config/network
   config host                → /etc/config/dhcp
   config policy(CustRule)    → /etc/config/pbr
   config dbroute             → dbroute.nft + dbroute-domains.conf（DBR）
   config pushkey             → .secrets/pushkey.*（推播 key）
   config linecmd             → 執行白名單維運指令（LineCMD）
   config crontab             → /etc/crontabs/root
```

- **`--only <段>`**：只同步部分段（見 sync-googleconfig-only.md）。
- **`--force`**：即使內容沒變也強制重套。
- **上傳**：`sync-uploadconfig.sh` 反向把本機 WG/DDNS 設定加密上傳回 Sheet（備份）。

---

## 5. 各子系統一覽（怎麼互動 + 指向細節 doc）

### 網路出口決策（同戶方案核心）
```
DNS 解析 → 填 nft set → 打 fwmark → ip rule → 出對的介面
```
- **DBR**（域名路由）：Netflix 功能→VPN、影片→WAN。→ [DBR-PBR-routing.md]、[MAINTAINER-GUIDE-netflix-dbr.md]
- **PBR**（來源 IP 路由）：CustRule 依 client IP 走指定 wg。→ [DBR-PBR-routing.md]
- **DNS 鏈**：client :53 →（有 AGH）hijack 到 AGH:53535 → 上游。→ AGH/DNS doc（待補）
- **DNS 繞過防護**：AAAA 擋 + Block-LAN-IPv6-ToRouter。→ [private-dns-doh.md]、[firewall-direction-basics.md]

### VPN
- **WireGuard**：wg0-wg5 等隧道,PBR/DBR 的出口。→ WireGuard doc（待補）
- **tailscale/headscale**：mesh 節點互通 + exit node。→ tailscale doc（待補）
- **ZeroTier**：備援進機路。→ [zerotier-backup-vpn.md]

### 自癒 / 監控（watchdog 群）
- **check-pbr-wg.sh**：wg 介面健檢 + DBR 健檢 + failover。→ DBR doc §健檢
- **ts-watchdog.sh**：tailscale exit node / 節點互通自癒。→ watchdog doc（待補）
- **watchdog.sh / wg-*/wifi-monitor**：各類守護。→ watchdog doc（待補）

### 無線
- **auto-role 頻道政策**：5G 依角色錯頻、2.4G 限 1-5 避 Zigbee。→ wifi doc（待補）
- **wifi-signal / wifi-usteer**：功率調整、漫遊引導。→ wifi doc（待補）

### 推播 / 遠端維運
- **push-notify.inc**：PushDeer/LINE 多通道分流。→ [line-push-and-linecmd.md]
- **LineCMD**：Sheet 下發白名單維運指令。→ [line-push-and-linecmd.md]
- **push-queue**：離線佇列（斷網時排隊,開機補送）。→ 推播 doc（待補）

### 部署 / 落地
- **sync-deploy.sh**：GitHub → /etc/myscript。→ 部署 doc（待補）
- **sync-ram2flash.sh**：RAM overlay 機器落地 flash。→ [ram-overlay-sync-flash.md] ⚠️
- **deploy.sh**：新機初始化（裝套件、建 firewall、AGH、secrets）。→ 部署 doc（待補）

### 上游設備
- **Hitron**（cable modem）：hitron-pf（port forward 同步）、hitron_reboot。→ hitron doc（待補）

---

## 6. 給接手者的最快路徑

1. **先讀這份**（全局）→ 建立整體圖。
2. **要碰 Netflix/DBR** → [MAINTAINER-GUIDE-netflix-dbr.md]。
3. **要碰防火牆** → [firewall-direction-basics.md]（先搞懂 input/forward）。
4. **手動改 RAM overlay 機器** → [ram-overlay-sync-flash.md]（別漏 sync-ram2flash）。
5. **具體識別值/密鑰** → 本機 `memory/`（不在公開 repo）。

> 標「（待補）」的子系統 doc 會分批補上。索引見 [README.md]。
