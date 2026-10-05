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
        $safeDetail = ([string]$Detail) -replace '[\r\n]+', ' '
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

function Get-CodexTurnDurationMs {
    param([string]$ThreadId, [string]$TurnId)

    if ($DurationMsOverride -ge 0) {
        return $DurationMsOverride
    }

    $rolloutPath = Find-CodexRolloutPath -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($rolloutPath)) {
        return $null
    }

    $candidateLines = @(Get-Content -LiteralPath $rolloutPath -Tail 600)
    if (-not ($candidateLines -match [regex]::Escape($TurnId))) {
        $candidateLines = @(Select-String -LiteralPath $rolloutPath -SimpleMatch -Pattern $TurnId |
            ForEach-Object { $_.Line })
    }

    $startedAtSeconds = $null
    foreach ($line in $candidateLines) {
        try {
            $entry = $line | ConvertFrom-Json
            if ($entry.type -ne "event_msg" -or [string]$entry.payload.turn_id -ne $TurnId) {
                continue
            }

            if ($entry.payload.type -eq "task_started") {
                $startedAtSeconds = [long]$entry.payload.started_at
            }
            elseif ($entry.payload.type -eq "task_complete" -and $null -ne $entry.payload.duration_ms) {
                return [long]$entry.payload.duration_ms
            }
        }
        catch {
            continue
        }
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

function Test-AndRecordNotification {
    param([string]$DedupeKey, [scriptblock]$SendAction)

    if ($DryRun -or [string]::IsNullOrWhiteSpace($DedupeKey)) {
        return (& $SendAction)
    }

    $mutex = New-Object Threading.Mutex($false, "Local\CodexBarkNotifierState")
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne(20000)
        if (-not $hasLock) {
            Write-BarkHookLog -EventName "dedupe" -Status "timeout" -Detail $DedupeKey
            return (& $SendAction)
        }

        $now = [DateTimeOffset]::UtcNow
        $entries = @()
        if (Test-Path -LiteralPath $StatePath) {
            try {
                $saved = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
                $entries = @($saved.entries | Where-Object {
                    $sentAt = [DateTimeOffset]::MinValue
                    [DateTimeOffset]::TryParse([string]$_.sent_at, [ref]$sentAt) -and $sentAt -gt $now.AddHours(-24)
                })
            }
            catch {
                $entries = @()
            }
        }

        if ($entries | Where-Object { [string]$_.key -eq $DedupeKey }) {
            Write-BarkHookLog -EventName "dedupe" -Status "ignored" -Detail $DedupeKey
            return $false
        }

        $sent = & $SendAction
        if ($sent) {
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
        [string]$LogDetail
    )

    $requestBodyObject = @{
        device_key = ""
        title      = $Title
        body       = $Body
        group      = "Codex"
        level      = $Level
    }

    if ($DryRun) {
        $requestBodyObject.Remove("device_key")
        $dryRunBody = $requestBodyObject | ConvertTo-Json -Compress
        Write-BarkHookLog -EventName $EventName -Status "dry-run" -Detail $LogDetail
        return $dryRunBody
    }

    return Test-AndRecordNotification -DedupeKey $DedupeKey -SendAction {
        $secretPath = Join-Path $env:USERPROFILE ".codex\secrets\bark-device-key.dpapi"
        if (-not (Test-Path -LiteralPath $secretPath)) {
            Write-BarkHookLog -EventName $EventName -Status "failed" -Detail "secret missing"
            return $false
        }

        $encryptedKey = (Get-Content -LiteralPath $secretPath -Raw).Trim()
        $secureKey = ConvertTo-SecureString $encryptedKey
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        try {
            $deviceKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
        }

        $requestBodyObject.device_key = $deviceKey
        $requestBody = $requestBodyObject | ConvertTo-Json -Compress
        Invoke-RestMethod `
            -Uri "https://api.day.app/push" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $requestBody `
            -TimeoutSec $RequestTimeoutSeconds | Out-Null
        Write-BarkHookLog -EventName $EventName -Status "sent" -Detail $LogDetail
        return $true
    }
}

$hookEventName = ""
try {
    if ([string]::IsNullOrWhiteSpace($NotificationJson)) {
        $NotificationJson = [Console]::In.ReadToEnd()
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
        $taskName = Get-CodexTaskName -ThreadId $threadId
        if ([string]::IsNullOrWhiteSpace($taskName)) {
            $taskName = $UnnamedTaskText
        }

        switch ($hookEventName) {
            "PermissionRequest" {
                $requestText = [string]$notification.tool_input.description
                if ([string]::IsNullOrWhiteSpace($requestText)) {
                    $requestText = [string]$notification.tool_name
                }
                if ($requestText.Length -gt 120) {
                    $requestText = $requestText.Substring(0, 120)
                }
                $body = "$TaskLabel$taskName`n$RequestLabel$requestText`n$PermissionBodyText"
                $result = Send-BarkNotification -EventName "permission" -Title $PermissionTitle -Body $body -Level "timeSensitive" -DedupeKey "" -LogDetail "task=$taskName tool=$($notification.tool_name)"
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
    $result = Send-BarkNotification -EventName "complete" -Title $CompleteTitle -Body $body -Level "active" -DedupeKey $key -LogDetail "task=$taskName durationMs=$durationMs"
    if ($DryRun) { $result }
}
catch {
    Write-BarkHookLog -EventName $(if ($hookEventName) { $hookEventName } else { "unknown" }) -Status "failed" -Detail ($_.Exception.GetType().Name)
    if (-not [string]::IsNullOrWhiteSpace($hookEventName) -and -not $DryRun) {
        [Console]::Out.WriteLine("{}")
    }
}
