# docs 索引

這批機器（OpenWrt 多機隊 + Google Sheet 集中設定 + tailscale/headscale + 自動角色切換）
的維護文件。

> 📐 **接手先讀 [ARCHITECTURE.md](ARCHITECTURE.md)** — 頂層全局架構（機器角色、設定/腳本
> 兩條分發線、開機流程、各子系統怎麼互動）。看懂整體再查下面各子系統細節。

## 核心：路由決策（同戶方案）

| 文件 | 內容 |
|------|------|
| [MAINTAINER-GUIDE-netflix-dbr.md](MAINTAINER-GUIDE-netflix-dbr.md) | **Netflix/DBR 接手先讀**。心智模型、設計決策（§2.1 ECS/同戶、§2.2 不做 v6 DBR）、踩過的坑、診斷 SOP |
| [DBR-PBR-routing.md](DBR-PBR-routing.md) | DBR/PBR 機制細節（table 別名、fwmark、資料流、除錯指令、健檢） |
| [sync-googleconfig-only.md](sync-googleconfig-only.md) | `--only` 部分同步用法 |

## 防火牆 / DNS

| 文件 | 內容 |
|------|------|
| [firewall-direction-basics.md](firewall-direction-basics.md) | 防火牆三方向（input/output/forward）+ LuCI 欄位對照。**設規則前先讀** |
| [private-dns-doh.md](private-dns-doh.md) | 私人 DNS/DoH/DoT 為什麼擋不乾淨、iOS vs Android、四層擋法 |

## 網路基礎設施

| 文件 | 內容 |
|------|------|
| [auto-role.md](auto-role.md) | ⚠️ **角色切換大腦**（主/副 gateway/client）。會覆蓋很多 uci 設定，改前必看 |
| [alfred-mesh-sync-issue.md](alfred-mesh-sync-issue.md) | ⚠️ **未解問題**：alfred 資料跨機不互通 → 仲裁失效 → 雙主搶 IP。已排除的死路 + 待試方向 |
| [tailscale.md](tailscale.md) | tailscale/headscale mesh + exit node + 定時開關 |
| [zerotier-backup-vpn.md](zerotier-backup-vpn.md) | ZeroTier 備援 VPN 建置 + 加節點 SOP + 三個坑 |

## 監控 / 自癒

| 文件 | 內容 |
|------|------|
| [watchdogs.md](watchdogs.md) | watchdog 群（對外連線/wg/DBR/tailscale/peer）各守什麼、怎麼修 |
| [MULTIPEER-FAILOVER-SUMMARY.md](MULTIPEER-FAILOVER-SUMMARY.md) | 多 peer failover 摘要 |

## 無線

| 文件 | 內容 |
|------|------|
| [wifi.md](wifi.md) | 頻道政策（5G 錯頻、2.4G 避 Zigbee）、功率管理、漫遊引導 |

## 維運機制

| 文件 | 內容 |
|------|------|
| [ram-overlay-sync-flash.md](ram-overlay-sync-flash.md) | ⚠️ **RAM overlay 陷阱**：手動 uci 不 sync-ram2flash → 重開機消失。通用必看 |
| [line-push-and-linecmd.md](line-push-and-linecmd.md) | LINE 推播多通道分流 + LineCMD 遠端維運白名單 |
| [upstream-and-misc.md](upstream-and-misc.md) | 上游 Hitron cable modem、推播離線佇列、AGH/DNS 鏈、雜項工具 |

## 部署

| 文件 | 內容 |
|------|------|
| [deployment.md](deployment.md) | deploy.sh（新機初始化）/ sync-deploy.sh（腳本更新）/ sync-ram2flash（落地）。⚠️ deploy.sh 的 firewall 規則不隨 sync-deploy |

## 敏感資訊放哪

具體識別值（ZeroTier network/node id、成員 IP、密碼、公網 IP、headscale login-server、
各機 SSH/角色細節）放在本機 `memory/`（不進公開 git）。這些 doc 用佔位符
（`<NETWORK_ID>` 等），真實值查 memory。
