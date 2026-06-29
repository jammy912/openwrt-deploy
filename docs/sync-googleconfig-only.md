# sync-googleconfig `--only` 部分同步說明

> 對應 `deploy/etc/myscript/sync-googleconfig.sh`。
> 用途：多台機器共用同一支 `sync-googleconfig.sh`，但執行時只套用指定的 config 段。

## TL;DR

```sh
# 只套 dbroute，其餘段一律跳過
/etc/myscript/sync-googleconfig.sh --apply --only dbroute

# 同時只套 dbroute + dhcp（逗號分隔，不要有空格）
/etc/myscript/sync-googleconfig.sh --apply --only dbroute,dhcp

# 等價寫法
/etc/myscript/sync-googleconfig.sh --apply --only=dbroute
```

- `--only` **不是無條件硬刷**：它強制流程「跑得到」指定段的比對與套用，但該段內容沒變時仍然會跳過。
- 不帶 `--only` 時，腳本本來就是逐段差異比對；日常只改某一段、跑一次 `--apply`，自然只動那段。`--only` 的價值在於「**強制只處理某幾段、忽略其他段的既有差異**」這種維運場景。

---

## 可用段名

| 段名 | 對應 config |
|------|-------------|
| `network` | 網路介面 |
| `dhcp` | DHCP / DNS |
| `pbr` | PBR（含 CustRule） |
| `qos_rules` | QoS 規則 |
| `qos_interfaces` | QoS 介面 |
| `crontab` | 排程 |
| `dbroute` | 域名路由（見 [DBR-PBR-routing.md](./DBR-PBR-routing.md)） |
| `routerconfig` | RouterConfig |
| `routerconfig_hitron` | RouterConfig（Hitron 數據機 port forwarding） |

> 未知段名會印錯誤並 `exit 2`，例如 `--only foobar`。

---

## `--only` 到底「強制」什麼？

`--only` **強制的是「不被 MD5 快取攔在門外」**，讓流程一定能跑到指定段的比對與套用邏輯。
**它不強制「內容沒變也硬重套」**：

```
--only dbroute，但 dbroute 內容跟 dbroute.state 一樣
   → check_content_changed 回「無變化」
   → CHANGED_DBROUTE=0
   → 「所有配置均無變化，無需更新」→ exit（不會重灌 nft / 不跑 dbroute-setup）
```

| 階段 | 不帶 `--only` | 帶 `--only dbroute` |
|------|--------------|---------------------|
| 伺服器端 MD5 短路（不帶 `&md5=`） | Sheet 沒變 → 回空白 → 直接退出 | **繞過**，強制回完整 payload |
| 本地全域 MD5 短路 | 沒變 → 直接退出 | **繞過**，往下走逐段比對 |
| 逐段內容比對 | 每段比各自 `.state` | 一樣比，但**只留白名單段，其餘 `CHANGED_*` 歸零** |
| 指定段（dbroute） | 內容變了才套 | 內容變了才套（**這點相同**） |
| 結尾寫全域 MD5 / 上傳 Sheet | 寫 / 上傳 | **不寫 / 不上傳** |

---

## 為什麼 `--only` 要繞過/跳過三道 MD5 短路（設計理由）

這支腳本有多層 MD5 快取早退，是為了「Sheet 沒變就快速退出、不浪費資源」。但對 `--only` 來說，這些早退會造成 **「被排除的段以後永遠同步不到」** 的隱性 bug，因此 `--only` 模式特別處理：

1. **伺服器端不帶 `&md5=`**
   下載 URL 不附舊 MD5，強迫 server 回完整 payload。
   *否則*：Sheet 整體 MD5 相同時 server 回空白 → 腳本提前 `exit 0`，根本進不到 dbroute。
   （與 `--dump` 同樣處理。）

2. **本地開頭全域 MD5 早退繞過**
   不比對全域 MD5，強制往下走完整解密 + 逐段比對。
   *效果*：即使 Sheet 沒有「新」變動，你仍能用 `--only` 把某段重新比對/套用一次。

3. **結尾不寫全域 MD5、不上傳 Sheet**
   *否則*：把「只套了一部分」的狀態記成「整份已同步」。
   舉例：Sheet 同時改了 `dbroute` 和 `dhcp`，你只跑 `--only dbroute`。
   若這時寫了全域 MD5 → 下次正常跑時，開頭/伺服器端 MD5 都「沒變」→ **`dhcp` 永遠補不上**。
   `--only` 不寫全域 MD5，下次正常執行仍會走完整逐段比對，把 `dhcp` 補回。

> 各段自己的 `.state` 檔天生安全：被跳過的段不執行 `update_state_file`，其 `.state` 維持舊值，下次正常執行仍會偵測到差異並補上。`--only` 需要額外處理的只有「全域 MD5」這層共用快取。

---

## 常見場景

| 想做的事 | 指令 |
|----------|------|
| 這台只更 dbroute，別碰其他段 | `--apply --only dbroute` |
| 只更 dbroute + dhcp | `--apply --only dbroute,dhcp` |
| 先看會下載/解出什麼，不動系統 | `--dump` |
| 完整同步（所有有變動的段） | `--apply`（不帶 `--only`） |

> 注意：`--only` 內容沒變時仍會「無需更新」退出。若需求是「**內容沒變也硬重套**」（例如手動清掉 state 後想強制重生成 nft），目前 `--only` 不保證——需另加 `--force` 之類旗標，尚未實作。

---

## 相關檔案

| 檔案 | 路徑 | 說明 |
|------|------|------|
| sync-googleconfig | `/etc/myscript/sync-googleconfig.sh` | 主腳本，`--only` 邏輯在此 |
| 各段 state | `/tmp/sync-state/<段>.state` | 逐段內容快取（判斷該段是否有變） |
| 全域 MD5 | `/tmp/config_base64.md5` | 整份 Sheet payload 的 MD5，全域快速早退用；`--only` 模式不寫入 |
