# RAM overlay 與 sync-ram2flash：手動改 uci 後不落地 = 重開機消失

> ⚠️ **這批機器的共通陷阱,不限任何主題。** 手動 `uci` 改完設定,若沒跑
> `sync-ram2flash.sh`,重開機後改動全部消失。2026-07-07 就這樣掉了整套 Netflix
> 防護規則,查了半天才發現。**任何手動 uci/firewall 改動的收尾都要記得這條。**

---

## 架構：`/etc/config` 在 RAM（tmpfs），不是 flash

這批機器（`.1`/`.8`/`.9` 等 RAX3000Z/MX4200）用 **RAM overlay**：

```
mount | grep /etc/config
→ tmpfs on /etc/config type tmpfs   ← /etc/config 整個在 RAM!
```

意思是:
- `uci set ...; uci commit` → 只寫進 **RAM** 的 `/etc/config`
- **重開機** → RAM 清空 → 從 **flash** 的版本重建 `/etc/config`
- → 你手動改的、沒同步到 flash 的東西 **全部消失**

**為什麼這樣設計**:減少 flash 寫入(延長壽命)、設定跑在 RAM 較快。代價就是「改動要
主動落地」。

## 怎麼判斷一台是不是 RAM overlay

```sh
mount | grep -q '/etc/config.*tmpfs' && echo "RAM overlay(要 sync-ram2flash)" || echo "直接落 flash"
ls /etc/myscript/sync-ram2flash.sh   # 有這腳本通常就是 RAM overlay 機
```

## 落地指令：`sync-ram2flash.sh`

手動改完 uci **一定要**跑:

```sh
uci set ...; uci commit <config>       # 改設定(在 RAM)
/etc/init.d/<service> reload            # 讓改動生效
/etc/myscript/sync-ram2flash.sh         # ★ 落地 flash(否則重開機掉)
```

`sync-ram2flash.sh` 做的事:把 RAM 的 `/etc/config/*`、`/etc/crontabs/*` 複製到 flash
的 `/overlay/upper/etc/config/`(和 `/rom/overlay/upper/...`),重開機從這裡重建。

## 驗證是否真的落地

```sh
# RAM 版 == flash 版 才算落地成功
md5sum /etc/config/firewall /overlay/upper/etc/config/firewall
# 兩個 md5 一致 = 已落地;不一致 = 還沒 sync,重開機會掉

# 或直接看 flash 版有沒有你的改動
grep 'Block-LAN-IPv6-ToRouter' /overlay/upper/etc/config/firewall
```

## 什麼改動需要手動 sync、什麼不用

| 改動來源 | 要手動 sync 嗎 |
|---------|:-------------:|
| **手動 `uci set`**(你在 SSH 敲的) | ✅ **要**——這是最常漏的 |
| `sync-googleconfig`(Sheet 同步) | ❌ 它自己會落地(有內建機制) |
| `deploy.sh`(重跑部署) | ❌ 尾端通常會處理;但保險起見手動 uci 段落後仍可補跑 |
| 開機時服務自動重建(如 DBR ip rule 靠 hotplug) | ❌ 那些不寫 /etc/config,靠開機流程重建 |

**最常踩的**:SSH 進去手動 `uci add firewall rule` 加規則、`uci commit`、reload——看起來
生效了(nft 有規則),但**沒跑 sync-ram2flash → 重開機掉**。今天就是這樣掉了 Block-DoT/
Block-IPv6-WAN(後來改成 Block-LAN-IPv6-ToRouter,記得落地了)。

## 收尾檢查清單（手動改 RAM overlay 機器後）

1. `uci commit <config>` — 提交到 RAM
2. `/etc/init.d/<service> reload` — 生效
3. **`/etc/myscript/sync-ram2flash.sh`** — 落地 flash ★別漏
4. `md5sum /etc/config/X /overlay/upper/etc/config/X` — 確認一致
5. （可選）真的重開機驗證改動還在

## 相關

- 這條陷阱在 [`MAINTAINER-GUIDE-netflix-dbr.md`](MAINTAINER-GUIDE-netflix-dbr.md) §5 也有提醒。
- 非 RAM overlay 的獨立機器(如 `.6` RT-AC66U)`uci commit` 直接落 flash,不需此步。
