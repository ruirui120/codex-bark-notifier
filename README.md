# Codex Bark Notifier

在 Windows 上监听 Codex 生命周期事件，并在 Codex 停止工作、等待权限、需要用户继续处理或被中断时，通过 [Bark](https://github.com/Finb/Bark) 通知 iPhone。

默认行为：

- 每次主任务触发 `Stop` 时提醒，不设时长门槛；
- 请求命令、文件、网络或 MCP 权限时立即提醒；
- 人工中断任务时立即提醒；
- 任务正常结束、暂停等待输入或需要接管时，都会通过 `Stop` 提醒；
- 保留旧 `agent-turn-complete` 通知作为兼容兜底，并按 `turn_id` 去重，避免同一轮重复推送；
- 通知包含 Codex 任务名称；权限通知还会包含工具名称或请求说明；
- Hook 标准输入、标准输出和 Bark JSON 请求均强制使用 UTF-8，避免中文任务名或权限说明乱码；
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

3. 复制 hook 配置，并将 `YOUR_NAME` 替换为自己的 Windows 用户名：

```powershell
Copy-Item .\hooks.example.json "$env:USERPROFILE\.codex\hooks.json"
$hooksPath = "$env:USERPROFILE\.codex\hooks.json"
(Get-Content $hooksPath -Raw).Replace("YOUR_NAME", $env:USERNAME) | Set-Content $hooksPath -Encoding UTF8
```

如果已经有 `~/.codex/hooks.json`，请合并 `PermissionRequest`、`Stop` 和 `Interrupt` 三组配置，不要直接覆盖。

4. 重新打开 Codex，并按提示审核、信任新 hook；也可以在 Codex CLI 中使用 `/hooks` 查看和信任。

完整说明见 [docs/setup.md](docs/setup.md)。

## 测试

测试使用 `DryRun`，不会发送真实 Bark 消息。覆盖完成阈值、停止、权限申请、中断、中文任务名、Windows PowerShell 5.1 UTF-8 标准输入、DPAPI 解密和无关事件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-bark-notify.Tests.ps1
```

## 安全说明

- 不要把 Bark Device Key 写进脚本、提交记录、Issue 或截图。
- DPAPI 密文只能由创建它的 Windows 用户在原电脑上解密。
- `scripts/bark-notify.log` 可能包含任务名称，已加入 `.gitignore`。

## License

[MIT](LICENSE)
