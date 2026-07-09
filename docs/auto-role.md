# auto-role.sh：自動角色切換（多機隊的大腦）

> 55KB 的核心腳本。決定每台當 主gateway / 副gateway / client,並套用對應的
> IP/DHCP/頻道/IPv6/mesh 設定。**改它前先讀這份**——它會覆蓋很多 uci 設定,手動改
> 那些鍵會被它打回。

---

## 做什麼

每台**自己判斷**該當什麼角色,然後套用角色對應的網路設定。同一份 Sheet 設定,插哪台
當主閘道都行;主機掛了副機自動頂上。

**觸發時機**：rc.local 開機 / WAN hotplug 變化 / cron 定時。

> ⚠️ **已知問題**：主 gateway 仲裁靠 alfred 讀彼此 priority，但 **alfred 資料跨機不互通**
> （auto-role 靠 fallback 勉強收斂）。詳見 [alfred-mesh-sync-issue.md](alfred-mesh-sync-issue.md)。
> **防雙主搶 .1 的最後防線 = ARP DAD V2**(見下)。

### ARP DAD V2：防雙主搶 .1（IP 衝突）

alfred 仲裁不通時,兩台可能都判自己 primary → 都搶 `.1` → IP 衝突。DAD V2 是最後防線:
- **情境A(要搶 .1)**:探測前依 priority **退避** `(100-pri)*0.3s` → 高 pri 先佔,
  低 pri 等完探測就看到高 pri 已佔 → 讓位。**解決「同時開機都撲空都搶」的 race。**
- **情境B(已是 .1)**:持續 arping 偵測「.1 有沒有第二個 MAC」→ 有衝突就比 priority。
  **解決「搶到後不再探測,事後另一台也搶時永不發現」。**
- **確定性 tie-break**:衝突時 priority 大者留守;相同/讀不到 pri 時 **MAC 小者留守**
  → 保證**只一台讓位**(不會兩台都讓=沒人當主,也不會都留=雙主)。

## 角色判斷邏輯（階段順序）

## 角色判斷邏輯（階段順序）

```
0. 等網路就緒(WAN 有 IP 或 mesh 有鄰居)
   │
1. 決定角色來源(優先序):
   a. .mesh_role_override  ← Sheet「GW Mode」臨時強切(最高)
   b. .mesh_role           ← 部署時釘死: gateway/client 直接用
                              hybrid → 才往下自動偵測
   │
2. hybrid 自動偵測: 有 WAN → gateway;沒 WAN → client
   │
3. 主 gateway 仲裁: priority 大的優先,相同時 MAC 小的優先
   │  連外健檢: WAN ping 不通(重試3次)→ 暫降 priority=0 讓出主 gw
   ▼
   主 gateway / 副 gateway / client
```

**關鍵檔案**（Sheet 下發到 `/etc/myscript/`）：
| 檔案 | 意義 |
|------|------|
| `.mesh_role` | 部署釘死角色:`gateway`/`client`/`hybrid`(hybrid 才自動偵測) |
| `.mesh_role_override` | Sheet「GW Mode」臨時強切(最高優先) |
| `.mesh_priority` | 數字大=優先當主 gateway |
| `.mesh_wireless` / `.mesh_wired` | 無線/有線 mesh 開關(Y/N) |
| `.mesh_runiotwifi` | IOT WiFi 開關(脫離角色,獨立) |
| `.mesh_role`(結果) / `.mesh_gw_type` / `.mesh_role_active` | 判斷結果寫回,供其他腳本讀 |

## 角色決定後套用什麼（★會覆蓋 uci）

| 設定 | 主 gateway | 副 gateway | client |
|------|-----------|-----------|--------|
| LAN IP | `.1` | 靜態 | 靜態(from MAC/lease) |
| DHCP server | 開 | 關(ignore=1) | 關 |
| DHCP dhcp_option(gw/DNS) | 清除 | — | 指向 `192.168.1.1` |
| **IPv6 RA/DHCPv6** | `server`(主 gw 才發) | `disabled` | `disabled` |
| 5G 頻道政策 | 低頻 36/40/44/48 | 高頻 149/153/157/161/165 | 低頻 |
| 2.4G 頻道 | `1 2 3 4 5` + HT20(避 Zigbee,所有角色同) | 同 | 同 |

## ⚠️ 會被 auto-role 打回的手動改動（重要）

auto-role 每次跑都會確保這些值符合角色。**手動改這些 uci 鍵會被下一輪 auto-role 覆蓋**：
- `dhcp.lan.ra` / `dhcp.lan.dhcpv6`（主 gw 強制 `server`）——**這就是為什麼「手動關 v6 RA
  會被打回」**,擋 v6 要用 firewall（見 firewall-direction-basics.md）。
- `dhcp.lan.ignore` / `dhcp.lan.dhcpv4`（依角色）
- `dhcp.lan.dhcp_option`（client 指向主 gw）
- `wireless.*.channel` / `.channels` / `.htmode`（頻道政策）
- LAN `ipaddr`

**改這些之前先 grep auto-role 有沒有在管**,否則白改。

## 併發保護

- `/tmp/auto-role.lock`（PID 鎖,防 cron 重疊）
- 全域 cron 排隊鎖（`cron_global_lock`）
- **不受 agh_startup lock 限制**（它自己要判斷角色+停 AGH）

## 除錯

```sh
/etc/myscript/auto-role.sh --dry-run    # 只偵測不執行
/etc/myscript/auto-role.sh --debug      # 每步推播
logread -e auto-role | tail -30
cat /etc/myscript/.mesh_role /etc/myscript/.mesh_gw_type   # 當前判斷結果
```

## 相關

- 頻道政策細節見 [wifi.md]（待補）。
- 這台是不是 RAM overlay(改完要 sync-ram2flash)見 [ram-overlay-sync-flash.md]。
- 頂層角色圖見 [ARCHITECTURE.md] §2。
