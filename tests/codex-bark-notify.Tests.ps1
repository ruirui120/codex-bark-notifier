$ErrorActionPreference = "Stop"

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\codex-bark-notify.ps1"
$testLogPath = Join-Path ([IO.Path]::GetTempPath()) "codex-bark-notify-tests-$PID.log"
$testProfile = Join-Path ([IO.Path]::GetTempPath()) "codex-bark-profile-$([guid]::NewGuid().ToString('N'))"
$originalUserProfile = $env:USERPROFILE
$payload = @{
    type = "agent-turn-complete"
    'thread-id' = "test-thread"
    'turn-id' = "test-turn"
} | ConvertTo-Json -Compress

function Invoke-DryRun {
    param([long]$DurationMs, [string]$EventPayload)

    if ([string]::IsNullOrWhiteSpace($EventPayload)) {
        $EventPayload = $script:payload
    }

    $output = & $scriptPath `
        -NotificationJson $EventPayload `
        -DryRun `
        -DurationMsOverride $DurationMs `
        -LogPath $testLogPath
    return ([string]($output -join "`n")).Trim()
}

try {
    if (-not [string]::IsNullOrWhiteSpace((Invoke-DryRun -DurationMs 179999))) {
        throw "A task shorter than 180 seconds must not notify."
    }

    $atThreshold = Invoke-DryRun -DurationMs 180000
    if ([string]::IsNullOrWhiteSpace($atThreshold)) {
        throw "A task lasting exactly 180 seconds must notify."
    }
    $thresholdBody = $atThreshold | ConvertFrom-Json
    $expectedTitle = '"Codex \u4efb\u52a1\u5df2\u5b8c\u6210"' | ConvertFrom-Json
    $expectedDuration = '"\u8017\u65f6\uff1a3\u52060\u79d2"' | ConvertFrom-Json
    if ($thresholdBody.title -ne $expectedTitle -or $thresholdBody.body -notmatch $expectedDuration) {
        throw "The notification at the threshold has unexpected content."
    }

    if ([string]::IsNullOrWhiteSpace((Invoke-DryRun -DurationMs 180001))) {
        throw "A task longer than 180 seconds must notify."
    }

    $fixtureThread = "fixture-thread"
    $fixtureTurn = "fixture-turn"
    $fixtureDirectory = Join-Path $testProfile ".codex\sessions\2026\09\10"
    New-Item -ItemType Directory -Force -Path $fixtureDirectory | Out-Null
    $fixturePath = Join-Path $fixtureDirectory "rollout-$fixtureThread.jsonl"
    $fixtureLine = @{
        timestamp = "2026-09-10T00:04:00Z"
        type = "event_msg"
        payload = @{
            type = "task_complete"
            turn_id = $fixtureTurn
            duration_ms = 240000
        }
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value $fixtureLine
    $expectedTaskName = '"\u4e2d\u6587\u4efb\u52a1\u540d\u79f0"' | ConvertFrom-Json
    $indexLine = @{
        id = $fixtureThread
        thread_name = $expectedTaskName
        updated_at = "2026-09-10T00:00:00Z"
    } | ConvertTo-Json -Compress
    $indexPath = Join-Path $testProfile ".codex\session_index.jsonl"
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($indexPath, $indexLine, $utf8WithoutBom)
    $env:USERPROFILE = $testProfile
    $fixturePayload = @{
        type = "agent-turn-complete"
        'thread-id' = $fixtureThread
        'turn-id' = $fixtureTurn
    } | ConvertTo-Json -Compress
    $fixtureOutput = Invoke-DryRun -DurationMs -1 -EventPayload $fixturePayload
    if ([string]::IsNullOrWhiteSpace($fixtureOutput)) {
        throw "The hook must read duration_ms from the matching local rollout."
    }
    $fixtureBody = ($fixtureOutput | ConvertFrom-Json).body
    if ($fixtureBody -notmatch [regex]::Escape($expectedTaskName)) {
        throw "The hook must preserve a UTF-8 task name from session_index.jsonl."
    }

    $otherEvent = @{ type = "approval-requested" } | ConvertTo-Json -Compress
    if (-not [string]::IsNullOrWhiteSpace((Invoke-DryRun -DurationMs 300000 -EventPayload $otherEvent))) {
        throw "Unrelated events must not notify."
    }

    "All codex-bark-notify tests passed."
}
finally {
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $testLogPath) {
        Remove-Item -LiteralPath $testLogPath -Force
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTestProfile = [IO.Path]::GetFullPath($testProfile)
    if ((Test-Path -LiteralPath $resolvedTestProfile) -and $resolvedTestProfile.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestProfile -Recurse -Force
    }
}

