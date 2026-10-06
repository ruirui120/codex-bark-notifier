param(
    [Parameter(Position = 0)]
    [string]$NotificationJson,
    [switch]$DryRun,
    [ValidateRange(0, 86400)]
    [int]$MinimumDurationSeconds = 180,
    [long]$DurationMsOverride = -1,
    [ValidateRange(1, 30)]
    [int]$RequestTimeoutSeconds = 15,
    [string]$LogPath,
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
$NotifierBuild = "2026-10-07.1"
$LogContext = ""
$Utf8WithoutBom = New-Object Text.UTF8Encoding($false)
$OutputEncoding = $Utf8WithoutBom
try {
    [Console]::OutputEncoding = $Utf8WithoutBom
}
catch {
    # Some non-console hosts do not allow changing their output encoding.
}

function Read-Utf8StandardInput {
    $standardInput = [Console]::OpenStandardInput()
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $reader = New-Object IO.StreamReader($standardInput, $strictUtf8, $true)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Unprotect-BarkDeviceKey {
    param([string]$EncryptedKey)

    if ([string]::IsNullOrWhiteSpace($EncryptedKey) -or
        ($EncryptedKey.Length % 2) -ne 0 -or
        $EncryptedKey -notmatch '\A[0-9a-fA-F]+\z') {
        throw "The Bark secret is not a valid DPAPI payload."
    }

    $cipherBytes = New-Object byte[] ($EncryptedKey.Length / 2)
    $plainBytes = $null
    try {
        if ($null -eq ("System.Security.Cryptography.ProtectedData" -as [type])) {
            [void][Reflection.Assembly]::Load(
                "System.Security, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a"
            )
        }
        for ($index = 0; $index -lt $cipherBytes.Length; $index++) {
            $cipherBytes[$index] = [Convert]::ToByte($EncryptedKey.Substring($index * 2, 2), 16)
        }
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $cipherBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::Unicode.GetString($plainBytes)
    }
    finally {
        [Array]::Clear($cipherBytes, 0, $cipherBytes.Length)
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot "bark-notify.log"
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $env:USERPROFILE ".codex\state\bark-notifier.json"
}

$UnnamedTaskText = '"\u672a\u547d\u540d\u4efb\u52a1"' | ConvertFrom-Json
$TaskLabel = '"\u4efb\u52a1\uff1a"' | ConvertFrom-Json
$DurationLabel = '"\u8017\u65f6\uff1a"' | ConvertFrom-Json
$RequestLabel = '"\u8bf7\u6c42\uff1a"' | ConvertFrom-Json
$MinuteText = '"\u5206"' | ConvertFrom-Json
$SecondText = '"\u79d2"' | ConvertFrom-Json

$CompleteTitle = '"Codex \u4efb\u52a1\u5df2\u5b8c\u6210"' | ConvertFrom-Json
$StopTitle = '"Codex \u672c\u8f6e\u5de5\u4f5c\u5df2\u505c\u6b62"' | ConvertFrom-Json
$PermissionTitle = '"Codex \u9700\u8981\u6743\u9650\u786e\u8ba4"' | ConvertFrom-Json
$InterruptTitle = '"Codex \u4efb\u52a1\u5df2\u4e2d\u65ad"' | ConvertFrom-Json
$SessionEndTitle = '"Codex \u4f1a\u8bdd\u5df2\u7ed3\u675f"' | ConvertFrom-Json

$CompleteBodyText = '"\u8bf7\u56de\u5230\u7535\u8111\u67e5\u770b\u7ed3\u679c\u3002"' | ConvertFrom-Json
$StopBodyText = '"\u672c\u8f6e\u5de5\u4f5c\u5df2\u7ed3\u675f\u6216\u6682\u505c\uff0c\u8bf7\u56de\u5230\u7535\u8111\u67e5\u770b\u7ed3\u679c\u6216\u7ee7\u7eed\u4efb\u52a1\u3002"' | ConvertFrom-Json
$PermissionBodyText = '"\u8bf7\u56de\u5230\u7535\u8111\u5904\u7406\u6743\u9650\u8bf7\u6c42\u3002"' | ConvertFrom-Json
$InterruptBodyText = '"\u4efb\u52a1\u5df2\u88ab\u4e2d\u65ad\uff0c\u8bf7\u56de\u5230\u7535\u8111\u67e5\u770b\u3002"' | ConvertFrom-Json
$SessionEndBodyText = '"\u4f1a\u8bdd\u5df2\u7ed3\u675f\uff0c\u8bf7\u56de\u5230\u7535\u8111\u67e5\u770b\u3002"' | ConvertFrom-Json

function Write-BarkHookLog {
    param([string]$EventName, [string]$Status, [string]$Detail = "")

    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 262144) {
            Clear-Content -LiteralPath $LogPath
        }
        $safeDetail = ("build=$NotifierBuild $LogContext $Detail").Trim() -replace '[\r\n]+', ' '
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value "$(Get-Date -Format o)`t$EventName`t$Status`t$safeDetail"
    }
    catch {
        # Diagnostics must never affect Codex.
    }
}

function Get-CodexTaskName {
    param([string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return ""
    }

    $indexPath = Join-Path $env:USERPROFILE ".codex\session_index.jsonl"
    if (-not (Test-Path -LiteralPath $indexPath)) {
        return ""
    }

    $taskName = ""
    foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
        try {
            $entry = $line | ConvertFrom-Json
            if ([string]$entry.id -eq $ThreadId -and -not [string]::IsNullOrWhiteSpace([string]$entry.thread_name)) {
                $taskName = ([string]$entry.thread_name).Trim()
            }
        }
        catch {
            continue
        }
    }

    if ($taskName.Length -gt 80) {
        return $taskName.Substring(0, 80)
    }
    return $taskName
}

function Find-CodexRolloutPath {
    param([string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return $null
    }

    $codexHome = Join-Path $env:USERPROFILE ".codex"
    foreach ($folder in @("sessions", "archived_sessions")) {
        $root = Join-Path $codexHome $folder
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*$ThreadId*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $match) {
            return $match.FullName
        }
    }

    return $null
}

function Get-CodexSessionKind {
    param([string]$ThreadId, [string]$TranscriptPath)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return "unknown" }
    $stream = $null
    $reader = $null
    try {
        $path = $TranscriptPath
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            $path = Find-CodexRolloutPath -ThreadId $ThreadId
        }
        if ([string]::IsNullOrWhiteSpace($path)) { return "unknown" }
        $sharedAccess = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharedAccess)
        $reader = New-Object IO.StreamReader($stream, $Utf8WithoutBom)
        # session_meta is the rollout header. Do not parse an entire active task.
        for ($index = 0; $index -lt 20 -and $null -ne ($line = $reader.ReadLine()); $index++) {
            if ($line -notmatch '"type"\s*:\s*"session_meta"') { continue }
            $entry = $line | ConvertFrom-Json
            if ($entry.type -ne "session_meta") { continue }
            if ([string]$entry.payload.id -ne $ThreadId) { continue }
            $source = $entry.payload.source
            if (($source -is [string] -and $source -match '^subagent') -or $null -ne $source.subagent) {
                return "subagent"
            }
            # Unknown/ephemeral sessions can have no persisted metadata at all.
            # Only a matching, explicitly recognized main source may notify.
            if ($source -is [string] -and $source -in @("cli", "vscode", "exec", "appServer", "app_server")) {
                return "main"
            }
            return "unknown"
        }
        return "unknown"
    }
    catch { return "unknown" }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-ApprovalReviewer {
    param($Notification)

    if ([string]$Notification.approvals_reviewer -eq "guardian_subagent") { return "auto_review" }
    if ([string]$Notification.approvals_reviewer -in @("user", "auto_review")) {
        return [string]$Notification.approvals_reviewer
    }

    # The UI can override config.toml per task. Read the effective current turn,
    # not a global default or a previous turn's approval mode.
    $reader = $null
    try {
        $path = [string]$Notification.transcript_path
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            $path = Find-CodexRolloutPath -ThreadId ([string]$Notification.session_id)
        }
        if ([string]::IsNullOrWhiteSpace($path)) { return "unknown" }
        $reviewer = "unknown"
        # Active rollouts are open for writing. Explicit shared access prevents
        # File.ReadLines from failing while Codex is still executing this turn.
        $sharedAccess = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharedAccess)
        $reader = New-Object IO.StreamReader($stream, $Utf8WithoutBom)
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -notmatch '"type"\s*:\s*"turn_context"') { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.type -ne "turn_context") { continue }
                if (-not [string]::IsNullOrWhiteSpace([string]$Notification.turn_id) -and
                    [string]$entry.payload.turn_id -ne [string]$Notification.turn_id) { continue }
                $value = [string]$entry.payload.approvals_reviewer
                if ($value -eq "guardian_subagent") {
                    $reviewer = "auto_review"
                }
                elseif ($value -in @("user", "auto_review")) {
                    $reviewer = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($value) -and $null -ne $entry.payload.approval_policy) {
                    # Older Codex versions omitted the default manual reviewer.
                    $reviewer = "user"
                }
            }
            catch { continue }
        }
        return $reviewer
    }
    catch { return "unknown" }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

function Test-RequiresHumanApproval {
    param($Notification)

    if ([string]$Notification.permission_mode -in @("dontAsk", "bypassPermissions")) { return $false }
    $reviewer = Get-ApprovalReviewer -Notification $Notification
    if ($reviewer -eq "user") { return $true }
    return $false
}

function Get-PermissionDedupeKey {
    param($Notification)

    $inputJson = $Notification.tool_input | ConvertTo-Json -Depth 30 -Compress
    if ([string]::IsNullOrEmpty($inputJson)) { $inputJson = "null" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha.ComputeHash($Utf8WithoutBom.GetBytes([string]$inputJson))).Replace("-", "")
    }
    finally { $sha.Dispose() }
    return "permission:$($Notification.session_id):$($Notification.turn_id):$($Notification.tool_name):$digest"
}

function Get-CodexTurnDurationMs {
    param([string]$ThreadId, [string]$TurnId)

    if ([string]::IsNullOrWhiteSpace($ThreadId) -or [string]::IsNullOrWhiteSpace($TurnId)) {
        return $null
    }
    if ($DurationMsOverride -ge 0) {
        return $DurationMsOverride
    }

    $rolloutPath = Find-CodexRolloutPath -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($rolloutPath)) {
        return $null
    }

    $startedAtSeconds = $null
    $stream = $null
    $reader = $null
    try {
        # Shared forward reads also handle active video/image transcripts with
        # long lines, where Get-Content -Tail can stall beyond the hook timeout.
        $sharedAccess = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($rolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharedAccess)
        $reader = New-Object IO.StreamReader($stream, $Utf8WithoutBom)
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf($TurnId, [StringComparison]::Ordinal) -lt 0 -or
                $line -notmatch '"type"\s*:\s*"task_(started|complete)"') { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.type -ne "event_msg" -or [string]$entry.payload.turn_id -ne $TurnId) { continue }
                if ($entry.payload.type -eq "task_started" -and $null -ne $entry.payload.started_at -and
                    [long]$entry.payload.started_at -gt 0) {
                    $startedAtSeconds = [long]$entry.payload.started_at
                }
                elseif ($entry.payload.type -eq "task_complete" -and $null -ne $entry.payload.duration_ms) {
                    return [long]$entry.payload.duration_ms
                }
            }
            catch { continue }
        }
    }
    catch { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }

    if ($null -ne $startedAtSeconds) {
        $elapsedSeconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $startedAtSeconds
        if ($elapsedSeconds -ge 0) {
            return $elapsedSeconds * 1000
        }
    }

    return $null
}

function Format-Duration {
    param([long]$DurationMs)

    $totalSeconds = [Math]::Floor($DurationMs / 1000)
    $minutes = [Math]::Floor($totalSeconds / 60)
    $seconds = $totalSeconds % 60
    return "$minutes$MinuteText$seconds$SecondText"
}

function Get-CodexRateLimits {
    param([int]$TimeoutMilliseconds = 3000)

    $process = $null
    try {
        $codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($null -eq $codexCommand) { return $null }
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $codexCommand.Source
        $startInfo.Arguments = "app-server"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $timer = [Diagnostics.Stopwatch]::StartNew()
        [void]$process.Start()
        # Drain stderr without exposing configuration or authentication details.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-bark-notifier","version":"1.0"}}}')
        $waitingForId = 1
        while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            $readTask = $process.StandardOutput.ReadLineAsync()
            $remainingMs = [Math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
            if (-not $readTask.Wait($remainingMs) -or $null -eq $readTask.Result) { return $null }
            $response = $readTask.Result | ConvertFrom-Json
            if ($response.id -ne $waitingForId) { continue }
            if ($null -ne $response.error) { return $null }
            if ($waitingForId -eq 1) {
                $process.StandardInput.WriteLine('{"method":"initialized"}')
                $process.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read"}')
                $waitingForId = 2
                continue
            }
            if ($null -ne $response.result.rateLimitsByLimitId) {
                return $response.result.rateLimitsByLimitId.codex
            }
            return $response.result.rateLimits
        }
        return $null
    }
    catch {
        # Quota lookup must never prevent a task notification.
        return $null
    }
    finally {
        if ($null -ne $process) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            $process.Dispose()
        }
    }
}

function Format-CodexQuota {
    param($RateLimits)

    $unavailable = '"\u6682\u4e0d\u53ef\u7528"' | ConvertFrom-Json
    $fiveHourLabel = '"\u4e94\u5c0f\u65f6\u5269\u4f59\uff1a"' | ConvertFrom-Json
    $sevenDayLabel = '"\u4e03\u5929\u5269\u4f59\uff1a"' | ConvertFrom-Json
    $remaining = @{ 300 = $unavailable; 10080 = $unavailable }
    foreach ($window in @($RateLimits.primary, $RateLimits.secondary)) {
        try {
        if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
        $minutes = [int]$window.windowDurationMins
        if (-not $remaining.ContainsKey($minutes)) { continue }
        $used = 0.0
        if (-not [double]::TryParse([string]$window.usedPercent, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$used) -or
            [double]::IsNaN($used) -or [double]::IsInfinity($used)) { continue }
        if ($null -ne $window.resetsAt -and [long]$window.resetsAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { continue }
        $percent = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $used))
        $remaining[$minutes] = $percent.ToString("0.#", [Globalization.CultureInfo]::InvariantCulture) + "%"
        }
        catch {
            continue
        }
    }
    return "$fiveHourLabel$($remaining[300])`n$sevenDayLabel$($remaining[10080])"
}

function Test-AndRecordNotification {
    param([string]$DedupeKey, [scriptblock]$SendAction, [int]$DedupeWindowSeconds = 86400)

    if ($DryRun -or [string]::IsNullOrWhiteSpace($DedupeKey)) {
        return (& $SendAction)
    }

    $mutex = New-Object Threading.Mutex($false, "Local\CodexBarkNotifierState")
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne(20000)
        if (-not $hasLock) {
            Write-BarkHookLog -EventName "dedupe" -Status "timeout" -Detail $DedupeKey
            return $false
        }

        $now = [DateTimeOffset]::UtcNow
        $entries = @()
        if (Test-Path -LiteralPath $StatePath) {
            try {
                $saved = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $entries = @($saved.entries | Where-Object {
                    $sentAt = [DateTimeOffset]::MinValue
                    [DateTimeOffset]::TryParse([string]$_.sent_at, [ref]$sentAt) -and $sentAt -gt $now.AddHours(-24)
                })
            }
            catch {
                $entries = @()
            }
        }

        if ($entries | Where-Object {
            [string]$_.key -eq $DedupeKey -and
            [DateTimeOffset]::Parse([string]$_.sent_at) -gt $now.AddSeconds(-$DedupeWindowSeconds)
        }) {
            Write-BarkHookLog -EventName "dedupe" -Status "ignored" -Detail $DedupeKey
            return $false
        }

        $sent = & $SendAction
        if ($sent) {
            $entries = @($entries | Where-Object { [string]$_.key -ne $DedupeKey })
            $entries += [pscustomobject]@{ key = $DedupeKey; sent_at = $now.ToString("o") }
            $stateDirectory = Split-Path -Parent $StatePath
            New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
            @{ entries = $entries } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
        }
        return $sent
    }
    finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Send-BarkNotification {
    param(
        [string]$EventName,
        [string]$Title,
        [string]$Body,
        [string]$Level,
        [string]$DedupeKey,
        [string]$LogDetail,
        [int]$DedupeWindowSeconds = 86400
    )

    $requestBodyObject = @{
        device_key = ""
        title      = $Title
        body       = $Body
        group      = "Codex"
        level      = $Level
    }

    if ($DryRun) {
        $requestBodyObject.body = "$Body`n`n$(Format-CodexQuota -RateLimits $null)"
        $requestBodyObject.Remove("device_key")
        $dryRunBody = $requestBodyObject | ConvertTo-Json -Compress
        Write-BarkHookLog -EventName $EventName -Status "dry-run" -Detail $LogDetail
        return $dryRunBody
    }

    return Test-AndRecordNotification -DedupeKey $DedupeKey -DedupeWindowSeconds $DedupeWindowSeconds -SendAction {
        $secretPath = Join-Path $env:USERPROFILE ".codex\secrets\bark-device-key.dpapi"
        if (-not (Test-Path -LiteralPath $secretPath)) {
            Write-BarkHookLog -EventName $EventName -Status "failed" -Detail "secret missing"
            return $false
        }

        $encryptedKey = (Get-Content -LiteralPath $secretPath -Raw).Trim()
        $deviceKey = Unprotect-BarkDeviceKey -EncryptedKey $encryptedKey

        $quotaTimeoutMs = 3000
        if ($EventName -eq "interrupt") { $quotaTimeoutMs = 500 }
        $rateLimits = Get-CodexRateLimits -TimeoutMilliseconds $quotaTimeoutMs
        $requestBodyObject.body = "$Body`n`n$(Format-CodexQuota -RateLimits $rateLimits)"
        $requestBodyObject.device_key = $deviceKey
        $requestBody = $requestBodyObject | ConvertTo-Json -Compress
        $requestBodyBytes = $Utf8WithoutBom.GetBytes($requestBody)
        Invoke-RestMethod `
            -Uri "https://api.day.app/push" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $requestBodyBytes `
            -TimeoutSec $RequestTimeoutSeconds | Out-Null
        Write-BarkHookLog -EventName $EventName -Status "sent" -Detail $LogDetail
        return $true
    }
}

$hookEventName = ""
try {
    if ([string]::IsNullOrWhiteSpace($NotificationJson)) {
        $NotificationJson = Read-Utf8StandardInput
    }
    if ([string]::IsNullOrWhiteSpace($NotificationJson)) {
        Write-BarkHookLog -EventName "unknown" -Status "ignored" -Detail "empty payload"
        return
    }

    $notification = $NotificationJson | ConvertFrom-Json
    $hookEventName = [string]$notification.hook_event_name

    if (-not [string]::IsNullOrWhiteSpace($hookEventName)) {
        $threadId = [string]$notification.session_id
        $turnId = [string]$notification.turn_id
        $LogContext = "origin=hook thread=$threadId turn=$turnId"
        if ($hookEventName -in @("Stop", "Interrupt", "SessionEnd")) {
            $sessionKind = Get-CodexSessionKind -ThreadId $threadId -TranscriptPath ([string]$notification.transcript_path)
            if ($sessionKind -ne "main") {
                Write-BarkHookLog -EventName "hook" -Status "ignored" -Detail "session-kind=$sessionKind event=$hookEventName"
                if (-not $DryRun) { [Console]::Out.WriteLine("{}") }
                return
            }
        }
        if ($hookEventName -in @("Stop", "Interrupt")) {
            $durationMs = Get-CodexTurnDurationMs -ThreadId $threadId -TurnId $turnId
            $minimumDurationMs = [long]$MinimumDurationSeconds * 1000
            if ($null -eq $durationMs -or $durationMs -lt $minimumDurationMs) {
                $durationDetail = if ($null -eq $durationMs) { "unavailable" } else { [string]$durationMs }
                Write-BarkHookLog -EventName "hook" -Status "ignored" -Detail "event=$hookEventName durationMs=$durationDetail thresholdMs=$minimumDurationMs"
                if (-not $DryRun) { [Console]::Out.WriteLine("{}") }
                return
            }
        }
        $taskName = Get-CodexTaskName -ThreadId $threadId
        if ([string]::IsNullOrWhiteSpace($taskName)) {
            $taskName = $UnnamedTaskText
        }

        switch ($hookEventName) {
            "PermissionRequest" {
                if (-not (Test-RequiresHumanApproval -Notification $notification)) {
                    Write-BarkHookLog -EventName "permission" -Status "ignored" -Detail "not-routed-to-human tool=$($notification.tool_name) turn=$turnId"
                    break
                }
                $requestText = [string]$notification.tool_input.description
                if ([string]::IsNullOrWhiteSpace($requestText)) {
                    $requestText = [string]$notification.tool_name
                }
                if ($requestText.Length -gt 120) {
                    $requestText = $requestText.Substring(0, 120)
                }
                $body = "$TaskLabel$taskName`n$RequestLabel$requestText`n$PermissionBodyText"
                $key = Get-PermissionDedupeKey -Notification $notification
                $result = Send-BarkNotification -EventName "permission" -Title $PermissionTitle -Body $body -Level "timeSensitive" -DedupeKey $key -LogDetail "task=$taskName tool=$($notification.tool_name)"
                if ($DryRun) { $result }
            }
            "Stop" {
                $body = "$TaskLabel$taskName`n$StopBodyText"
                $key = "turn:$threadId`:$turnId"
                $result = Send-BarkNotification -EventName "stop" -Title $StopTitle -Body $body -Level "active" -DedupeKey $key -LogDetail "task=$taskName turn=$turnId"
                if ($DryRun) { $result }
            }
            "Interrupt" {
                $body = "$TaskLabel$taskName`n$InterruptBodyText"
                $key = "turn:$threadId`:$turnId"
                $result = Send-BarkNotification -EventName "interrupt" -Title $InterruptTitle -Body $body -Level "timeSensitive" -DedupeKey $key -LogDetail "task=$taskName turn=$turnId"
                if ($DryRun) { $result }
            }
            "SessionEnd" {
                $body = "$TaskLabel$taskName`n$SessionEndBodyText"
                $key = "session:$threadId`:end"
                $result = Send-BarkNotification -EventName "session-end" -Title $SessionEndTitle -Body $body -Level "active" -DedupeKey $key -LogDetail "task=$taskName reason=$($notification.reason)"
                if ($DryRun) { $result }
            }
            default {
                Write-BarkHookLog -EventName "hook" -Status "ignored" -Detail "event=$hookEventName"
            }
        }

        if (-not $DryRun) {
            [Console]::Out.WriteLine("{}")
        }
        return
    }

    if ($notification.type -ne "agent-turn-complete") {
        Write-BarkHookLog -EventName "complete" -Status "ignored" -Detail "event=$($notification.type)"
        return
    }

    $threadId = [string]$notification.'thread-id'
    $turnId = [string]$notification.'turn-id'
    $LogContext = "origin=notify thread=$threadId turn=$turnId"
    $sessionKind = Get-CodexSessionKind -ThreadId $threadId
    if ($sessionKind -ne "main") {
        Write-BarkHookLog -EventName "complete" -Status "ignored" -Detail "session-kind=$sessionKind"
        return
    }
    $durationMs = Get-CodexTurnDurationMs -ThreadId $threadId -TurnId $turnId
    $minimumDurationMs = [long]$MinimumDurationSeconds * 1000
    if ($null -eq $durationMs) {
        Write-BarkHookLog -EventName "complete" -Status "ignored" -Detail "duration unavailable turn=$turnId"
        return
    }
    if ($durationMs -lt $minimumDurationMs) {
        Write-BarkHookLog -EventName "complete" -Status "ignored" -Detail "durationMs=$durationMs thresholdMs=$minimumDurationMs"
        return
    }

    $taskName = Get-CodexTaskName -ThreadId $threadId
    if ([string]::IsNullOrWhiteSpace($taskName)) {
        $taskName = $UnnamedTaskText
    }
    $durationText = Format-Duration -DurationMs $durationMs
    $body = "$TaskLabel$taskName`n$DurationLabel$durationText`n$CompleteBodyText"
    $key = "turn:$threadId`:$turnId"
    $result = Send-BarkNotification -EventName "complete" -Title $CompleteTitle -Body $body -Level "active" -DedupeKey $key -LogDetail "task=$taskName durationMs=$durationMs sessionKind=$sessionKind"
    if ($DryRun) { $result }
}
catch {
    $failedCommand = [string]$_.InvocationInfo.MyCommand.Name
    $failedLine = [int]$_.InvocationInfo.ScriptLineNumber
    $failureMessage = ([string]$_.Exception.Message) -replace '(?i)\b[0-9a-f]{32,}\b', '[redacted]'
    if ($failureMessage.Length -gt 160) {
        $failureMessage = $failureMessage.Substring(0, 160)
    }
    $failureDetail = "$($_.Exception.GetType().Name) line=$failedLine command=$failedCommand message=$failureMessage"
    Write-BarkHookLog -EventName $(if ($hookEventName) { $hookEventName } else { "unknown" }) -Status "failed" -Detail $failureDetail
    if (-not [string]::IsNullOrWhiteSpace($hookEventName) -and -not $DryRun) {
        [Console]::Out.WriteLine("{}")
    }
}
