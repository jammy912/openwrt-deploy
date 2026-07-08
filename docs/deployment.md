# 部署鏈：deploy.sh / sync-deploy.sh / sync-ram2flash

> 腳本與設定怎麼落到機器上。分三條路:新機初始化(deploy.sh)、日常腳本更新
> (sync-deploy.sh)、RAM overlay 落地(sync-ram2flash.sh)。**三者範圍不同,搞混會
> 出現「某台沒某規則」。**

---

## 兩條「集中 → 分發」的線（先分清）

| | 設定 | 腳本 |
|---|------|------|
| 來源 | Google Sheet(加密) | GitHub main |
| 落地工具 | `sync-googleconfig.sh` | `sync-deploy.sh` |
| 落到 | `/etc/config/*`(network/dhcp/pbr...) | `/etc/myscript/*`、init.d、hotplug、rc.local |
| 頻率 | 每分鐘 cron / rc.local / 手動 | 手動 / cron |

---

## 三條部署路徑

### 1. `deploy.sh`（新機初始化，repo 根目錄）

**只在新機第一次部署、或想重套 firewall/AGH 時手動跑。** 做的事:
- 裝必要套件(check-custpkgs)
- 建 firewall zone / rule（VPN zone、adgh hijack redirect、**Block-LAN-IPv6-ToRouter**、
  Allow-Tailscale-UDP 等）
- AGH 客製化(upstream DoT/DoH、AAAA 擋、快取、DoH canary)
- 寫 `.secrets`(secret.url/key/iv、tdx、line.token)
- WiFi 初始設定(頻道、國碼、SSID)
- dnsmasq / qosify / sysupgrade.conf 等

⚠️ **最重要的認知**:**deploy.sh 裡的 firewall 規則,`sync-deploy.sh` 不會帶下去。**
sync-deploy 只同步 `/etc/myscript` 等腳本目錄,**不含 deploy.sh**。所以:
- 「只跑過 sync-deploy 的機器」**不會自動有 deploy.sh 裡的 firewall 規則**。
- 要那些規則 → **重跑 deploy.sh**,或手動下對應 uci(各 commit 訊息有指令)。
- **這是最常見的「某台沒防護/沒某規則」原因。**

### 2. `sync-deploy.sh`（日常腳本更新）

```
GitHub main(tarball)
   │  hash 比對(有變才更新)
   ▼
etc/myscript / etc/init.d / etc/hotplug.d / etc/rc.local
   (.secrets 排除,不覆蓋本機密鑰;dbroute.nft 排除)
```

用法:
```sh
/etc/myscript/sync-deploy.sh                    # 正常同步(有變動才更新)
/etc/myscript/sync-deploy.sh --check            # 只比對,有差異推播,不覆蓋
/etc/myscript/sync-deploy.sh --force            # 強制覆蓋
/etc/myscript/sync-deploy.sh --only "a.sh,b.sh" # ★只同步指定檔(basename),其餘完全不碰
```

- **`--only <檔名清單>`**:只更新點名的檔(用 basename 比對,逗號/空白分隔),**未指定
  的檔完全不碰**(連 md5 比對都不做)。適合獨立體系機器只想更新某幾個腳本、不想動其他。
  可配 `--force`。例:`sync-deploy.sh --only "watchdog.sh,push-status.sh"`。
  注意 basename 精準比對——`watchdog.sh` 不會誤匹配 `wg-reboot-watchdog.sh`。

**流程**:push 腳本到 GitHub main → 各機 `sync-deploy.sh` → 落地。
- **獨立體系機器**(如 .6 RT-AC66U)**沒有 sync-deploy**,腳本要手動傳(scp/stdin),
  且推播模組名可能不同要適配。見 memory `independent-routers`。
  → 或用 `--only` 精準更新(若該機有 sync-deploy)。

### 3. `sync-ram2flash.sh`（RAM overlay 落地）

RAM overlay 機器(`/etc/config` 在 tmpfs)**手動改 uci 後必跑**,否則重開機掉。
詳見 [ram-overlay-sync-flash.md]。sync-googleconfig/deploy 自己會處理落地,**手動 uci 才需補**。

---

## 部署一台新機的完整順序

```
1. 刷 OpenWrt + 基本能上網 + 能 ssh
2. 傳/git clone deploy 到機器(或手動放 secret.url/key/iv)
3. 跑 deploy.sh:裝套件、建 firewall、AGH、寫 secrets、WiFi
   (互動問 Sheet URL/key/iv、root 密碼、TDX、line.token)
4. deploy.sh 尾端會測試 sync-googleconfig(驗證密鑰)
5. 設角色檔 .mesh_role / .mesh_priority(或 Sheet 下發)
6. rc.local 開機自動:掛 RAM overlay → auto-role → sync-googleconfig --apply
7. 之後日常:改腳本 push GitHub → 各機 sync-deploy;改設定 → 改 Sheet(自動同步)
```

---

## 部署一台新機的防護核對（Netflix 同戶）

deploy.sh 應建好這些(核對見 [MAINTAINER-GUIDE-netflix-dbr.md] §5):
- AAAA 擋(有 AGH: user_rules / 無 AGH: filter_aaaa)
- Block-LAN-IPv6-ToRouter
- DBR 域名分流(靠 Sheet dbroute 段 + sync)
- fwinclude 自癒

若某台缺,通常就是「只跑了 sync-deploy 沒重跑 deploy.sh」。

## 相關

- RAM overlay 落地 → [ram-overlay-sync-flash.md]
- 獨立體系機器手動傳 → memory `independent-routers`
- 頂層 → [ARCHITECTURE.md] §4
