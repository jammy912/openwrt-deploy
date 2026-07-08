# 無線（WiFi）管理

> 頻道政策、功率管理、漫遊引導、IOT WiFi。頻道由 auto-role 依角色套用,功率/漫遊由
> 獨立腳本管。

---

## 頻道政策（auto-role 套用）

### 5G：依角色錯頻（避免主副 gw 同頻干擾）
| 角色 | channels |
|------|----------|
| mesh radio(有 mesh 介面 + mesh_wireless=Y) | 固定 149 |
| 主 gw / client | 低頻 36 40 44 48 |
| 副 gw | 高頻 149 153 157 161 165 |

- **排除 DFS**(52-144,需雷達偵測不穩)+ **排除硬體不支援的**(`iw phy channels` 過濾)。
- 三頻機每個 phy 頻段不同,自動過濾到該 radio 支援的。

### 2.4G：限 channel 1-5 + HT20（避 Zigbee）
- `channels='1 2 3 4 5'` + `htmode='HT20'`,所有角色同。
- **原理**:WiFi 集中低頻(2401-2435),讓出高頻(2450-2480/Zigbee 20-26)給 Aqara/Zigbee。
  Aqara 官方網關自動選頻會避開被佔低頻→落到高頻乾淨區。HT20 佔用最窄不侵蝕高頻。
- 在 `wifi-setup.sh`(初始)+ `auto-role.sh` `apply_2g_channel_policy`(維護)。

---

## wifi-signal.sh（智慧功率管理 V7.3）

- 依 client 信號(RSSI)**動態調功率**:信號好→降功率省電/減干擾,信號差→升功率。
- **救援模式**:監控裝置斷線時升到 BOOST_PWR 一段時間。
- **無人降功率**:無 client 連線超時→降到最低功率。
- **踢客戶端**:`RSSI_KICK_5G/2G` 設定值時,信號太差的 client 踢掉重連(引導到更好的 AP)。
- 讀 `.mesh_runiotwifi` 決定 IOT WiFi(與 auto-role 同一真相來源,避免對打)。

## wifi-usteer.sh（漫遊引導）

設定 usteer(802.11k/v 漫遊)參數:signal 門檻、roam SNR、band steering、load kick 等
17 個參數(由 Sheet crontab 帶入)。讓 client 在多 AP 間平滑漫遊到信號最好的。

## 其他 wifi 工具

| 腳本 | 用途 |
|------|------|
| `wifi-ctrl.sh <radio> <ssid> <1/0>` | 啟用/停用特定 radio+SSID |
| `wifi-monitor.sh` | wifi 存活守護(觸發 signal) |
| `kick-wifi-client.sh <hostname> [ssid]` | 依 hostname 踢 client 重連 |

## 相關

- 頻道政策為何這樣設 → [auto-role.md]、Zigbee 避頻見本檔 2.4G 段
- 頂層 → [ARCHITECTURE.md] §5
