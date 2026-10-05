param(
    [Parameter(Position = 0)]
    [string]$NotificationJson,
    [switch]$DryRun,
    [ValidateRange(0, 86400)]
    [int]$MinimumDurationSeconds = 180,
    [long]$DurationMsOverride = -1,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot "bark-notify.log"
}

$UnnamedTaskText = '"\u672a\u547d\u540d\u4efb\u52a1"' | ConvertFrom-Json
$NotificationTitle = '"Codex \u4efb\u52a1\u5df2\u5b8c\u6210"' | ConvertFrom-Json
$TaskLabel = '"\u4efb\u52a1\uff1a"' | ConvertFrom-Json
$DurationLabel = '"\u8017\u65f6\uff1a"' | ConvertFrom-Json
$ReturnToComputerText = '"\u8bf7\u56de\u5230\u7535\u8111\u67e5\u770b\u7ed3\u679c\u3002"' | ConvertFrom-Json
$MinuteText = '"\u5206"' | ConvertFrom-Json
$SecondText = '"\u79d2"' | ConvertFrom-Json

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

try {
    if ([string]::IsNullOrWhiteSpace($NotificationJson)) {
        Write-BarkHookLog -EventName "complete" -Status "ignored" -Detail "empty payload"
        return
    }

    $notification = $NotificationJson | ConvertFrom-Json
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

    $requestBodyObject = @{
        device_key = ""
        title      = $NotificationTitle
        body       = "$TaskLabel$taskName`n$DurationLabel$durationText`n$ReturnToComputerText"
        group      = "Codex"
        level      = "active"
    }

    if ($DryRun) {
        $requestBodyObject.Remove("device_key")
        $requestBodyObject | ConvertTo-Json -Compress
        Write-BarkHookLog -EventName "complete" -Status "dry-run" -Detail "task=$taskName durationMs=$durationMs"
        return
    }

    $secretPath = Join-Path $env:USERPROFILE ".codex\secrets\bark-device-key.dpapi"
    if (-not (Test-Path -LiteralPath $secretPath)) {
        Write-BarkHookLog -EventName "complete" -Status "failed" -Detail "secret missing"
        return
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
        -TimeoutSec 15 | Out-Null
    Write-BarkHookLog -EventName "complete" -Status "sent" -Detail "task=$taskName durationMs=$durationMs"
}
catch {
    Write-BarkHookLog -EventName "complete" -Status "failed" -Detail ($_.Exception.GetType().Name)
}

