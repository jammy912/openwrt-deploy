# OpenWrt 自動部署腳本 (RAX3000Z)

## 這是什麼？

這是一套 OpenWrt 路由器的自動部署工具，適用於 RAX3000Z。
刷好 OpenWrt 韌體後，只要一行指令就能完成所有設定。

支援兩種角色：
- **Gateway（主路由）** — 接 ISP 數據機，負責撥號/DHCP/防火牆/VPN/DNS 等
- **Client（子路由）** — 透過 BATMAN mesh 連回主路由，只負責 WiFi 延伸

---

## 快速開始

### 第一步：刷好 OpenWrt

用 RAX3000Z 官方支援的 OpenWrt 韌體（24.10 或 25.x）刷入路由器。

### 第二步：SSH 登入路由器

```sh
ssh root@192.168.1.1
```

> 新刷的路由器預設 IP 是 `192.168.1.1`，密碼為空，直接按 Enter。

### 第三步：一鍵部署

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/jammy912/openwrt-deploy/main/install.sh)"
```

> **時間問題：** 新刷的路由器系統時間通常不對，會導致 HTTPS 憑證驗證失敗。
> 可以先設定時間再執行：
> ```sh
> date -s "2026-03-18 12:00:00"
> ```
> 或直接跳過 SSL 驗證（在自家網路上安全無虞）：
> ```sh
> sh -c "$(wget --no-check-certificate -qO- https://raw.githubusercontent.com/jammy912/openwrt-deploy/main/install.sh)"
> ```

---

## 部署流程（腳本會自動引導）

### 1. 選擇角色

```
請選擇角色:
  gateway = 主路由 (接 ISP 數據機，管理所有網路設定)
  client  = Mesh 子路由 (透過無線連回主路由，延伸覆蓋範圍)
角色 [gateway]:
```

- **Gateway**：安裝完整功能（PBR 分流、DDNS、QoS、WireGuard、DNS 管理）
- **Client**：只安裝基礎套件，由 Gateway 統一管理設定

> 選好後會寫入 `/etc/myscript/.mesh_role`，之後的腳本會自動判斷角色。

### 2. 安裝套件

腳本會根據角色安裝不同的套件：

| 套件 | Gateway | Client |
|------|:-------:|:------:|
| 基礎（curl, rsync, LuCI 中文化...） | ✅ | ✅ |
| AdGuard Home（DNS 廣告過濾） | ✅ | |
| dnsmasq-full（完整 DNS） | ✅ | |
| WireGuard（VPN） | ✅ | |
| PBR（分流路由） | ✅ | |
| DDNS（動態 DNS） | ✅ | |
| qosify（QoS 頻寬管理） | ✅ | |
| bind-dig（DNS 偵錯） | ✅ | |
| Tailscale（Headscale node，選裝） | ✅ | |

### 3. 選擇模組

腳本會逐一詢問是否安裝可選模組：

| 模組 | 說明 | 預設 |
|------|------|:----:|
| USB/Samba | USB 硬碟自動掛載 + 網路共享 | n |
| BATMAN mesh | 多台路由器組成無縫 mesh 網路 | y |
| Android 手機 USB 分享 | Android 手機 USB 網路共享 | n |
| iPhone USB 分享 | iPhone USB 網路共享 | n |
| Docker | 容器化平台 | n |
| Tailscale | 加入 Headscale mesh 當一個 node（不設 exit node） | n |

> 已安裝的模組會記錄在 `/etc/myscript/.modules`，開機時自動檢查。

#### Tailscale（Headscale node）

只在 **gateway** 詢問。選 y 後需輸入兩樣：

- **① Headscale URL**（例 `https://mxc5569.duckdns.org`）— 同時寫入 `uci tailscale.settings.custom_login_url`
- **② pre-auth key**（`hskey-auth-...`，headscale 後台產）— 一行登入

腳本自動完成：裝套件（tailscale / jq / luci app）→ 建 `network.tailscale` interface → 建 firewall zone `ts`（masq + mtu_fix + lan↔ts 雙向 forwarding，**LAN 與其他 node 互通**）→ 登入（`--accept-dns=false`）→ 加 `ts-watchdog.sh` cron（每天 04:00）。

> **定位 = 純 node**：不設 exit node、不裝 schedule 定時開關。
> 日後若要讓整個 LAN 走某 exit node：
> `tailscale set --exit-node=<IP> --exit-node-allow-lan-access=true --accept-dns=false`

**補裝到舊機器**（用沒有 tailscale 步驟的舊版 deploy 裝起來的）：上傳部署包後，直接單獨跑這支即可（會自我補齊三支 `ts-*.sh`）：

```sh
sh /tmp/deploy/tailscale-setup.sh
```

### 4. 部署設定檔與腳本

自動複製所有腳本到 `/etc/myscript/`，設定防火牆規則、開機啟動項等。

### 5. 輸入密鑰

腳本會要求輸入以下密鑰（每次部署都會重新輸入）：

- **Google Sheet 同步 URL** — 用於從 Google Sheet 拉取網路設定
- **AES 加密金鑰 (32 字元)** — 加密同步資料
- **AES IV (16 字元)** — 加密初始向量
- **TDX API 金鑰** — 公車到站查詢（選填）

> 密鑰存放在 `/etc/myscript/.secrets/`，權限為 700，不會上傳到 GitHub。

### 6. WiFi 設定（選填）

執行 `wifi-setup.sh`，會：
1. **清除所有舊 WiFi 介面**
2. 偵測所有 radio（2.4GHz / 5GHz）
3. 設定 5GHz 主要 WiFi（SSID、密碼、加密方式）
4. 建立 2.4GHz IOT WiFi（給智慧家電用）

> 所有 WiFi 變更在**重啟後才生效**，部署過程中不會斷線。

### 7. BATMAN Mesh 設定（選填，需安裝 BATMAN 模組）

執行 `batman-setup.sh`，會：
1. 在 5GHz radio 上建立 mesh 介面
2. 設定 BATMAN IV 路由協定
3. 對所有 AP 啟用 802.11r/k/v 快速漫遊

需要輸入的資訊（所有 mesh 節點必須一致）：
- **Mesh ID** — mesh 網路名稱（預設：`batmesh`）
- **Mesh 密碼** — 節點間通訊加密
- **Mobility Domain** — 漫遊群組識別碼（預設：`9797`）

### 8. Google Sheet 同步

自動執行第一次同步，從 Google Sheet 拉取：
- 網路設定（IP、DHCP、DNS）
- 防火牆規則
- PBR 分流規則
- QoS 頻寬設定
- 排程工作（crontab）

> 同步完成後會自動重啟路由器，之後每天 12:00 自動同步。

### 9. 重啟

所有設定完成，重啟後即可使用。

---

## Google Sheet 遠端管理

部署完成後，**日常設定改在 Google Sheet，不用 SSH 進機器**。
`sync-googleconfig.sh` 拉取加密設定，比對 MD5，偵測到變更才套用。

> 首次部署裝的是 `0 12 * * *`（每天一次）。實務上會再由 Sheet 的
> `config crontab` 下發更密的排程（現行機隊是 `*/1 0,7-23`，即營運時段每分鐘），
> 所以「改 Sheet 多久生效」取決於該台實際的 cron 行。

### 支援的段別

| 段別 | 用途 |
|------|------|
| `config interface` / `wireguard_wg` | 網路介面、WireGuard peer |
| `config host` | DHCP static 綁定（MAC ↔ IP ↔ 名稱） |
| `config policy` | PBR 分流規則 |
| `config dbroute` | 域名路由（DBR） |
| `config qosrule` / `qosinterface` | QoS 頻寬管理 |
| `config crontab` | 排程工作 |
| `config pushkey` | 推播金鑰 |
| `config routerconfig` | 路由器基本設定 |
| `config batmanmesh` | **逐台**覆寫 mesh / WiFi / 漫遊設定（見下） |
| `config linecmd` | **遠端下指令**（見下） |

> ⚠️ **任何 option 留白會讓「整份設定」都不套用**（驗證第 3 項會 `exit 1`），
> 不是只有那一欄失效。新增欄位時記得填值。

### config batmanmesh（依 hostname 逐台生效）

| option | 說明 |
|--------|------|
| `hostname` | 對應哪一台（必填，比對 `system.@system[0].hostname`） |
| `priority` | mesh 優先權，決定誰當主 gw |
| `gw_mode` | 強制角色；`Auto` 或留白 = 自動偵測 |
| `wireless_mesh` / `wired_mesh` | 無線 / 有線 mesh 開關（TRUE/FALSE） |
| `runagh` | 是否跑 AdGuard Home |
| `upstream_dns1`~`4` | 上游 DNS（可多個 IP，空白/逗號分隔） |
| `ch5g_main` / `ch5g_sub` / `ch5g_mesh` | 5G 頻道清單（主gw / 副gw / mesh backhaul） |
| `ch2g` | 2.4G 頻道 |
| `ht5g` / `ht2g` | 頻寬模式（HE80 / VHT80 / HT20…）；**留白 = 不碰**，保留手動值 |
| `ft_tracking_time` | 漫遊推播去重秒數；**`0` = 該台不跑 `check-roam`** |
| `ft_tracking_member` | 監看的裝置名樣式（逗號/分號/空白分隔）；**留白或 `ALL` = 全部** |

> 頻道與漫遊旗標改完**不用重開機**：sync 偵測到變更就寫旗標檔並自動重啟對應常駐。

### config linecmd（遠端下指令）

Sheet 只填**動作代號**，真正的指令由 `linecmd-handler.sh` 的 case 白名單決定；
對應不到就忽略 → 不可能注入任意指令。

| action | 參數 | 動作 |
|--------|------|------|
| `reboot` | — | 5 秒後重開（讓 sync 收尾） |
| `sync-force` | — | 強制重套全部段 |
| `wg-restart` | `wg0` / `wg2`… | ifdown → ifup（驗證介面存在） |
| `dbr-refresh` | — | 刷新 DBR nft set |
| `dbr-setup` | — | 重建 DBR ip rule/route |
| `pbr-reload` | — | 重套 CustRule PBR |
| `fw-reload` | — | firewall reload |
| `dnsmasq-restart` | — | dnsmasq restart |
| `blockdev` | `<裝置名清單>` + `add`/`del`/`status` | 依 DHCP 名稱封鎖／解封裝置上網 |

`blockdev` 範例（arg1 = 名字清單，arg2 = 動作，**順序不可顛倒**）：

```
option action 'blockdev'
list   arg    'TV_Apple,TV_Android,UBOX_PRO2,LGTV'
list   arg    'add'
```

> 要「定時封鎖／放行」請用 `config crontab` 下發 cron 行，
> 不要在 Sheet 裡串 `;` 或 `&&`──那會被當成字面字串擋掉。

---

## 常駐監控

| 腳本 | 作用 |
|------|------|
| `check-roam.sh` | 串流本機 hostapd `AP-STA-CONNECTED` 事件，FT 漫遊時推播。由 `rc.local` 啟動，`logread -f` 阻塞等事件，不輪詢 |
| `check-fserror.sh` | 每日唯讀檢查 USB 碟 ext4 錯誤計數並告警 |
| `check-openlist.sh` | OpenList 容器異常自動重啟 |
| `openlist-sync.sh` | 網盤 → SSD 暫存 → 8TB 歸檔 |
| `blockdev.sh` | 依 DHCP 名稱把裝置 IP 加入 `inet fw4` 的 `blocked` set |
| `auto-role.sh` | 角色自動偵測與切換（hybrid 模式） |
| `watchdog.sh` | 對外連線監測與自癒 |

> ⚠️ `blockdev.sh` 依賴 fw4 的 named set，**firewall restart 會清空整個 table**。
> 腳本每次執行都會重建 set + rule，但若在別處 reload 防火牆，已封鎖的裝置會被解開。

---

## Gateway vs Client 差異總覽

| | Gateway（主路由） | Client（子路由） |
|---|---|---|
| **接線** | WAN 接 ISP 數據機 | 不接 WAN，靠 mesh 無線回傳 |
| **IP** | 192.168.1.1 | 192.168.1.2（或其他） |
| **DHCP** | 管理整個網段 | 不跑 DHCP |
| **防火牆** | 完整規則（VPN、分流、DNS 重導） | 基本或無 |
| **VPN** | WireGuard 伺服器 + PBR 分流 | 不需要 |
| **DNS** | AdGuard Home + dnsmasq-full | 不需要 |
| **QoS** | qosify 頻寬管理 | 不需要 |
| **WiFi** | 5GHz AP + 2.4GHz IOT | 5GHz AP + 2.4GHz IOT |
| **BATMAN** | gw_mode=server | gw_mode=client |
| **Google Sheet 同步** | 完整同步 | 基本同步 |
| **套件檢查** | 完整套件清單 | 僅基礎套件 |

---

## 部署後管理

| 功能 | 網址 / 指令 |
|------|------------|
| LuCI 管理介面 | http://192.168.1.1 |
| AdGuard Home | http://192.168.1.1:3000（首次需設定密碼） |
| 手動同步 Google Sheet | `/etc/myscript/sync-googleconfig.sh --apply` |
| 預覽 Sheet 內容（不套用） | `/etc/myscript/sync-googleconfig.sh --dump` |
| 更新腳本（從 GitHub） | `/etc/myscript/sync-deploy.sh` |
| 檢查套件 | `/etc/myscript/check-custpkgs.sh --now` |
| 封鎖/解封裝置 | `/etc/myscript/blockdev.sh TV_Apple,LGTV add` / `del` / `status` |
| 查目前被封鎖的 IP | `/etc/myscript/blockdev.sh "" status` |
| WiFi 重新設定 | `sh /tmp/deploy/wifi-setup.sh` |
| BATMAN 重新設定 | `sh /tmp/deploy/batman-setup.sh` |
| Tailscale 安裝/補裝 | `sh /tmp/deploy/tailscale-setup.sh` |
| Tailscale node 狀態 | `tailscale status` |
| Tailscale 自癒日誌 | `logread \| grep ts-watchdog` |

---

## 檔案結構

```
deploy/
├── install.sh               # 一鍵安裝入口
├── deploy.sh                # 主部署腳本
├── wifi-setup.sh            # WiFi 設定
├── batman-setup.sh          # BATMAN mesh + 802.11r/k/v
├── tailscale-setup.sh       # Tailscale (Headscale node) 安裝 + 接線
├── etc/
│   ├── rc.local             # 開機啟動（RAM overlay）
│   ├── sysupgrade.conf      # 韌體升級保留檔案清單
│   ├── adguardhome/         # AdGuard Home 設定
│   ├── config/
│   │   └── qosify_template  # QoS 範本
│   ├── dnsmasq.d/           # DNS 域名路由設定
│   ├── hotplug.d/           # 事件觸發腳本
│   ├── init.d/              # 開機服務
│   └── myscript/            # 所有自訂腳本
│       ├── .secrets/        # 密鑰（不上傳 GitHub）
│       ├── sync-googleconfig.sh       # Google Sheet 同步（設定的總入口）
│       ├── sync-deploy.sh             # 從 GitHub 拉最新腳本落地
│       ├── linecmd-handler.sh         # LineCMD 白名單動作執行器
│       ├── blockdev.sh                # 依裝置名封鎖/解封上網
│       ├── check-custpkgs.sh          # 套件檢查
│       ├── check-roam.sh              # 漫遊偵測常駐（hostapd 事件）
│       ├── check-fserror.sh           # USB 碟檔案系統錯誤告警
│       ├── auto-role.sh               # 主/副 gw 角色自動偵測
│       ├── openlist-sync.sh           # 網盤下載 → SSD → 8TB 歸檔
│       ├── dbroute-*.sh               # 域名路由
│       ├── wifi-*.sh                  # WiFi 管理
│       ├── push-*.sh                  # 各類推播（狀態/WiFi/SMART/公車…）
│       └── ...
```

> 腳本共 40+ 支。已部署的機器要更新腳本，跑 `/etc/myscript/sync-deploy.sh`
> 從 GitHub 拉取即可，不必重跑整套部署。

---

## 常見問題

### Q: 部署過程中 WiFi 會斷線嗎？
不會。所有 WiFi 設定只寫入 UCI，要到**重啟後才會生效**。

### Q: 可以重複執行部署嗎？
可以。腳本設計為可重複執行（idempotent），防火牆規則會先檢查再新增，不會產生重複。

### Q: Client 需要先部署 Gateway 嗎？
建議先部署 Gateway，確認網路正常後再部署 Client。Client 需要 Gateway 的 DHCP 分配 IP。

### Q: 密碼忘了怎麼辦？
重新執行部署腳本，密鑰每次都會重新輸入。

### Q: 韌體升級後設定會消失嗎？
`sysupgrade.conf` 已設定保留 `/etc/myscript/` 目錄。但建議升級後重新執行部署腳本確保完整。
