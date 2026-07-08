# docs 索引

這批機器（OpenWrt 多機隊 + Google Sheet 同步 + tailscale/headscale）的維護文件。

> 📐 **先讀 [ARCHITECTURE.md](ARCHITECTURE.md)** — 頂層全局架構（機器角色、設定/腳本兩條
> 分發線、開機流程、各子系統怎麼互動）。看懂整體再查下面各子系統細節。

## Netflix 同戶 / DBR / PBR

| 文件 | 內容 |
|------|------|
| [MAINTAINER-GUIDE-netflix-dbr.md](MAINTAINER-GUIDE-netflix-dbr.md) | **接手先讀**。心智模型、設計決策（含 §2.1 ECS/同戶、§2.2 不做 v6 DBR）、踩過的坑、診斷 SOP |
| [DBR-PBR-routing.md](DBR-PBR-routing.md) | DBR/PBR 機制細節參考（table 別名、fwmark、資料流、除錯指令） |
| [sync-googleconfig-only.md](sync-googleconfig-only.md) | `--only` 部分同步用法 |

## 防火牆 / DNS

| 文件 | 內容 |
|------|------|
| [firewall-direction-basics.md](firewall-direction-basics.md) | 防火牆三方向（input/output/forward）+ LuCI 欄位對照 + v6 實例。**設規則前先讀** |
| [private-dns-doh.md](private-dns-doh.md) | 私人 DNS/DoH/DoT 為什麼擋不乾淨、iOS vs Android、四層擋法 |

## 維運機制

| 文件 | 內容 |
|------|------|
| [ram-overlay-sync-flash.md](ram-overlay-sync-flash.md) | ⚠️ **RAM overlay 陷阱**：手動 uci 改完不跑 sync-ram2flash → 重開機消失。通用必看 |
| [line-push-and-linecmd.md](line-push-and-linecmd.md) | LINE 推播（Messaging API）多通道分流 + LineCMD 遠端維運白名單機制 |
| [zerotier-backup-vpn.md](zerotier-backup-vpn.md) | ZeroTier 備援 VPN 建置 + 加節點 SOP + 三個坑（識別值見 memory，不進 repo） |
| [MULTIPEER-FAILOVER-SUMMARY.md](MULTIPEER-FAILOVER-SUMMARY.md) | 多 peer failover 摘要 |

## 敏感資訊放哪

具體識別值（ZeroTier network/node id、成員 IP、密碼、公網 IP、各機 SSH/角色細節）
放在本機 `memory/`（不進公開 git）。這些 doc 用佔位符（`<NETWORK_ID>` 等），真實值查 memory。
