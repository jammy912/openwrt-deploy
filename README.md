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

### 3. 選擇模組

腳本會逐一詢問是否安裝可選模組：

| 模組 | 說明 | 預設 |
|------|------|:----:|
| USB/Samba | USB 硬碟自動掛載 + 網路共享 | n |
| BATMAN mesh | 多台路由器組成無縫 mesh 網路 | y |
| Android 手機 USB 分享 | Android 手機 USB 網路共享 | n |
| iPhone USB 分享 | iPhone USB 網路共享 | n |
| Docker | 容器化平台 | n |

> 已安裝的模組會記錄在 `/etc/myscript/.modules`，開機時自動檢查。

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
| 手動同步 Google Sheet | `/etc/myscript/sync-googleconfig-v3.3.sh --apply` |
| 檢查套件 | `/etc/myscript/check-custpkgs.sh --now` |
| WiFi 重新設定 | `sh /tmp/deploy/wifi-setup.sh` |
| BATMAN 重新設定 | `sh /tmp/deploy/batman-setup.sh` |

---

## 檔案結構

```
deploy/
├── install.sh               # 一鍵安裝入口
├── deploy.sh                # 主部署腳本
├── wifi-setup.sh            # WiFi 設定
├── batman-setup.sh          # BATMAN mesh + 802.11r/k/v
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
│       ├── sync-googleconfig-v3.3.sh  # Google Sheet 同步
│       ├── check-custpkgs.sh          # 套件檢查
│       ├── dbroute-*.sh               # 域名路由
│       ├── wifi-*.sh                  # WiFi 管理
│       └── ...
```

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
