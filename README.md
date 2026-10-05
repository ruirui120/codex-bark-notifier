# Codex Bark Notifier

在 Windows 上监听 Codex 生命周期事件，并在 Codex 停止工作、等待权限、需要用户继续处理或被中断时，通过 [Bark](https://github.com/Finb/Bark) 通知 iPhone。

默认行为：

- 每次主任务触发 `Stop` 时提醒，不设时长门槛；
- 权限提醒按当前轮次的实际审批接收者判断：`user`（人工审批）才发送；`auto_review` / `guardian_subagent`（替我批准）不发送自动审批请求；不同人工请求分别提醒，仅相同请求去重；
- 人工中断任务时立即提醒；
- 任务正常结束、暂停等待输入或需要接管时，都会通过 `Stop` 提醒；
- 保留旧 `agent-turn-complete` 通知作为兼容兜底，并按 `turn_id` 去重，避免同一轮重复推送；
- 从会话日志的 `session_meta.source` 识别内部子任务，忽略其完成、停止、中断和会话结束事件，避免主任务仍在工作时误报“已完成”；不靠任务名判断，未命名的主任务仍可提醒；
- 通知包含 Codex 任务名称；权限通知还会包含工具名称或请求说明；
- 每条通知附带五小时和七天额度剩余百分比，发送前通过官方 `account/rateLimits/read` 只读接口刷新；按窗口时长识别，剩余 = 100% − 已用；
- 额度查询失败、缺少窗口或窗口已过期时显示“暂不可用”，不会阻止任务提醒；常规查询最多等 3 秒，中断提醒最多等 0.5 秒；
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

测试使用 `DryRun` 和模拟 HTTP，不会发送真实 Bark 消息。覆盖完成阈值、主任务与子任务识别、停止、人工/自动权限申请、中断、中文任务名、Windows PowerShell 5.1 UTF-8 标准输入、DPAPI 解密和无关事件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-bark-notify.Tests.ps1
```

## 安全说明

额度查询需要 `codex.exe` 在 PATH 中可用，并已登录 ChatGPT 账户。脚本启动一个隐藏的临时 `codex app-server` 进程读取额度，结束后关闭；不发起模型任务、不消耗重置次数，也不把登录凭据发送给 Bark。`DryRun` 不查询网络额度，显示“暂不可用”。

权限事件在审批开始前触发，不能等同于“正在等待用户”。脚本从 Hook 的 `transcript_path` 或该任务 rollout 中读取精确 `turn_id` 的 `turn_context.approvals_reviewer`，使用运行时设置，避免全局配置与任务界面的“替我批准”不一致。运行时信息无法确认时，只记录日志，不虚报人工权限提醒；自动审核拒绝后若任务停止，仍发送 `Stop` 提醒。Computer Use 原生应用授权等独立弹窗不保证触发 `PermissionRequest`，本脚本不声称覆盖所有此类弹窗；MCP/app 单独覆盖审批接收者时，需要 Hook 提供有效接收者或对应运行时信息。

- 不要把 Bark Device Key 写进脚本、提交记录、Issue 或截图。
- DPAPI 密文只能由创建它的 Windows 用户在原电脑上解密。
- `scripts/bark-notify.log` 可能包含任务名称，已加入 `.gitignore`。
- 日志包含脚本构建编号、通知入口（`hook` / `notify`）、会话 ID 和轮次 ID，便于区分旧版本、主任务及子任务事件；不会记录密钥或命令正文。

## License

[MIT](LICENSE)
