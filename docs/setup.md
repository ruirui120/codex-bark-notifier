# 安装与配置

[`scripts/codex-bark-notify.ps1`](../scripts/codex-bark-notify.ps1) 接收 Codex 的 `agent-turn-complete` 回调，并在本轮任务耗时达到 3 分钟时发送 Bark。

## 提醒规则

- 耗时小于 180 秒：不提醒；
- 耗时等于或大于 180 秒：任务结束时提醒；
- 找不到本轮耗时：不提醒，并在 `bark-notify.log` 中记录 `duration unavailable`；
- 其他类型的事件会被忽略。

Codex 的标准 `notify` JSON 包含 `thread-id` 和 `turn-id`，但不直接提供耗时。脚本使用这两个 ID 定位本机 `.codex/sessions` 中相同轮次的 `task_complete.duration_ms`，避免误用上一轮或另一个任务的耗时。

## 安装脚本

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\hooks" | Out-Null
Copy-Item .\scripts\codex-bark-notify.ps1 "$env:USERPROFILE\.codex\hooks\bark-notify.ps1"
```

## 保存 Bark Device Key

脚本从下面的 DPAPI 文件读取 Bark Device Key：

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

## 配置 Codex

在个人级 `~/.codex/config.toml` 中把 `notify` 指向脚本。Codex 会在 `agent-turn-complete` 时调用外部程序，并将通知 JSON 作为参数传给脚本：

```toml
notify = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\YOUR_NAME\\.codex\\hooks\\bark-notify.ps1"]
```

如果已有通知包装程序，应保留包装程序，并将这个脚本作为它的下游完成通知脚本。

## 修改时间阈值

默认值是 180 秒。可以在通知命令中增加参数，例如改成 5 分钟：

```toml
notify = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\YOUR_NAME\\.codex\\hooks\\bark-notify.ps1", "-MinimumDurationSeconds", "300"]
```

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-bark-notify.Tests.ps1
```

测试覆盖 179.999 秒、恰好 180 秒、超过 180 秒、UTF-8 中文任务名和非完成事件。测试使用 `DryRun`，不会发送真实消息。

## 日志

默认日志位置：

```text
scripts\bark-notify.log
```

日志超过 256 KiB 会自动清空。日志只记录状态和诊断信息，不记录 Bark Device Key。
