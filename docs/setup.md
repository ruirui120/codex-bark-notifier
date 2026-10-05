# 安装与配置

[`scripts/codex-bark-notify.ps1`](../scripts/codex-bark-notify.ps1) 同时支持 Codex 生命周期 hooks 和旧版 `notify` 回调。

## 提醒规则

| 事件 | 何时提醒 | Bark 标题 |
| --- | --- | --- |
| `Stop` | 主任务正常结束、暂停等待输入或需要用户继续处理 | Codex 本轮工作已停止 |
| `PermissionRequest` | Codex 请求命令、文件、网络或 MCP 权限 | Codex 需要权限确认 |
| `Interrupt` | 用户中断正在运行的主任务 | Codex 任务已中断 |
| `SessionEnd` | 会话关闭、归档或空闲结束；脚本支持但默认配置未启用 | Codex 会话已结束 |
| `agent-turn-complete` | 旧版兼容兜底；默认仅本轮达到 180 秒时提醒 | Codex 任务已完成 |

`Stop` 没有时长门槛，因此短任务只要结束或等待你处理也会提醒。`Stop`、`Interrupt` 和旧版完成通知使用相同的会话与轮次键去重，避免同一轮连续推送两次。

Codex 没有单独名为“接管”的 hook。需要权限的接管由 `PermissionRequest` 覆盖；Codex 输出问题并等待用户输入时会触发 `Stop`，因此也会提醒。

## 安装脚本

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\hooks" | Out-Null
Copy-Item .\scripts\codex-bark-notify.ps1 "$env:USERPROFILE\.codex\hooks\bark-notify.ps1"
```

## 保存 Bark Device Key

脚本从下面的 Windows DPAPI 文件读取 Bark Device Key：

```text
%USERPROFILE%\.codex\secrets\bark-device-key.dpapi
```

使用 PowerShell 交互式输入并加密保存：

```powershell
$secretDirectory = Join-Path $env:USERPROFILE ".codex\secrets"
New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
$secureKey = Read-Host "Bark Device Key" -AsSecureString
$secureKey | ConvertFrom-SecureString | Set-Content (Join-Path $secretDirectory "bark-device-key.dpapi")
```

不要把明文 Key 或 DPAPI 文件提交到 Git。

## 配置 Codex hooks

新安装可以复制示例文件，再替换用户名：

```powershell
Copy-Item .\hooks.example.json "$env:USERPROFILE\.codex\hooks.json"
$hooksPath = "$env:USERPROFILE\.codex\hooks.json"
(Get-Content $hooksPath -Raw).Replace("YOUR_NAME", $env:USERNAME) | Set-Content $hooksPath -Encoding UTF8
```

已有 `~/.codex/hooks.json` 时，请合并示例中的 `PermissionRequest`、`Stop` 和 `Interrupt`，不要覆盖其他 hooks。

重新打开 Codex 后必须审核并信任 hook。Codex 会按 hook 定义的哈希记录信任；脚本或配置变化后需要重新审核。可以在 Codex CLI 中运行 `/hooks` 查看状态。

默认没有配置 `SessionEnd`，因为它可能在会话空闲 30 分钟后再次推送，造成和 `Stop` 重复的体感。如果确实需要会话关闭提醒，可参照其他事件在 `hooks.json` 中增加 `SessionEnd`。

## 兼容旧版 `notify`

若已有 `~/.codex/config.toml` 的 `notify` 配置，可以保留。旧回调仍使用 180 秒阈值，并与 `Stop` 按 `turn_id` 去重；如果生命周期 hook 已经成功发送，旧回调不会再次推送。

旧回调的默认阈值可以通过 `-MinimumDurationSeconds` 修改。生命周期 `Stop` 不受这个参数影响。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-bark-notify.Tests.ps1
```

测试覆盖：

- 旧完成回调的 179.999 秒、恰好 180 秒和超过 180 秒；
- `Stop` 不受时长限制；
- `PermissionRequest` 包含请求说明；
- `Interrupt` 使用紧急提醒；
- UTF-8 中文任务名；
- 无关事件不会推送；
- `hooks.example.json` 包含三个默认事件。

测试使用 `DryRun`，不会发送真实 Bark 消息。

## 本地状态与日志

默认日志：

```text
scripts\bark-notify.log
```

默认去重状态：

```text
%USERPROFILE%\.codex\state\bark-notifier.json
```

状态文件只保存最近 24 小时的会话/轮次键和发送时间，不保存 Bark Device Key。日志超过 256 KiB 会自动清空。

## 官方依据

- [OpenAI Codex Hooks](https://learn.chatgpt.com/docs/hooks)
- `PermissionRequest` 在 Codex 准备请求权限时触发；
- `Stop` 在主任务一轮停止时触发；
- `Interrupt` 在用户中断活动任务时触发。
