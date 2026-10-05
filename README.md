# Codex Bark Notifier

在 Windows 上监听 Codex 的 `agent-turn-complete` 回调，并在单轮任务耗时达到设定阈值后，通过 [Bark](https://github.com/Finb/Bark) 通知 iPhone。

默认行为：

- 小于 3 分钟的任务不提醒；
- 达到或超过 3 分钟时，在任务完成后提醒；
- 通知包含 Codex 任务名称和本轮耗时；
- Bark Device Key 使用 Windows DPAPI 加密，只保存在本机，不写入脚本或仓库；
- 网络或脚本异常只写入本地日志，不影响 Codex 完成任务。

## 快速开始

1. 将脚本复制到个人 Codex hook 目录：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\hooks" | Out-Null
Copy-Item .\scripts\codex-bark-notify.ps1 "$env:USERPROFILE\.codex\hooks\bark-notify.ps1"
```

2. 交互式输入 Bark Device Key，并通过 DPAPI 加密保存：

```powershell
$secretDirectory = Join-Path $env:USERPROFILE ".codex\secrets"
New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
$secureKey = Read-Host "Bark Device Key" -AsSecureString
$secureKey | ConvertFrom-SecureString | Set-Content (Join-Path $secretDirectory "bark-device-key.dpapi")
```

3. 在 `~/.codex/config.toml` 中配置通知脚本：

```toml
notify = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\YOUR_NAME\\.codex\\hooks\\bark-notify.ps1"]
```

完整说明见 [docs/setup.md](docs/setup.md)。

## 测试

测试使用 `DryRun`，不会发送真实 Bark 消息：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-bark-notify.Tests.ps1
```

## 安全说明

- 不要把 Bark Device Key 写进脚本、提交记录、Issue 或截图。
- DPAPI 密文只能由创建它的 Windows 用户在原电脑上解密。
- `scripts/bark-notify.log` 可能包含任务名称，已加入 `.gitignore`。

## License

[MIT](LICENSE)
