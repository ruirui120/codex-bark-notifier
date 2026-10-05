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

function Invoke-HookDryRun {
    param([string]$EventName, [hashtable]$ExtraFields)

    $hookPayload = @{
        hook_event_name = $EventName
        session_id = "test-thread"
        turn_id = "test-turn"
        permission_mode = "default"
    }
    if ($null -ne $ExtraFields) {
        foreach ($key in $ExtraFields.Keys) {
            $hookPayload[$key] = $ExtraFields[$key]
        }
    }

    $output = & $scriptPath `
        -NotificationJson ($hookPayload | ConvertTo-Json -Depth 5 -Compress) `
        -DryRun `
        -LogPath $testLogPath
    return ([string]($output -join "`n")).Trim()
}

function Invoke-WindowsPowerShellStdinDryRun {
    param([string]$EventPayload)

    $powerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -DryRun -LogPath `"$testLogPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    $payloadBytes = $utf8WithoutBom.GetBytes($EventPayload)
    $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($standardError)) {
        throw "Windows PowerShell child process failed: $standardError"
    }
    return $standardOutput.Trim()
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

    $stopOutput = Invoke-HookDryRun -EventName "Stop"
    $expectedStopTitle = '"Codex \u672c\u8f6e\u5de5\u4f5c\u5df2\u505c\u6b62"' | ConvertFrom-Json
    if (($stopOutput | ConvertFrom-Json).title -ne $expectedStopTitle) {
        throw "Every Stop hook must create a Bark notification without a duration threshold."
    }

    $env:USERPROFILE = $testProfile
    try {
        $stopPayload = @{
            hook_event_name = "Stop"
            session_id = "test-thread"
            turn_id = "missing-secret-turn"
        } | ConvertTo-Json -Compress
        $hookResponse = $stopPayload | & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $scriptPath `
            -LogPath $testLogPath `
            -StatePath (Join-Path $testProfile ".codex\state\bark-notifier.json")
        if (([string]($hookResponse -join "`n")).Trim() -ne "{}") {
            throw "A Stop hook must return valid JSON even when Bark cannot be sent."
        }
    }
    finally {
        $env:USERPROFILE = $originalUserProfile
    }

    $permissionOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
        tool_name = "Bash"
        tool_input = @{ description = "Allow network access" }
    }
    $permissionBody = $permissionOutput | ConvertFrom-Json
    $expectedPermissionTitle = '"Codex \u9700\u8981\u6743\u9650\u786e\u8ba4"' | ConvertFrom-Json
    if ($permissionBody.title -ne $expectedPermissionTitle -or $permissionBody.body -notmatch "Allow network access") {
        throw "PermissionRequest must identify the approval request."
    }

    $expectedChineseRequest = '"\u5141\u8bb8\u7f51\u7edc\u8bbf\u95ee\u5e76\u7ee7\u7eed\u6267\u884c\u4e2d\u6587\u4efb\u52a1"' | ConvertFrom-Json
    $utf8StdinPayload = @{
        hook_event_name = "PermissionRequest"
        session_id = "utf8-stdin-thread"
        turn_id = "utf8-stdin-turn"
        tool_name = "Bash"
        tool_input = @{ description = $expectedChineseRequest }
    } | ConvertTo-Json -Depth 5 -Compress
    $utf8StdinOutput = Invoke-WindowsPowerShellStdinDryRun -EventPayload $utf8StdinPayload
    if ([string]::IsNullOrWhiteSpace($utf8StdinOutput)) {
        throw "Windows PowerShell 5.1 must accept UTF-8 hook JSON from standard input."
    }
    $utf8StdinBody = ($utf8StdinOutput | ConvertFrom-Json).body
    if ($utf8StdinBody -notmatch [regex]::Escape($expectedChineseRequest)) {
        throw "UTF-8 hook input must preserve Chinese notification text."
    }

    $interruptOutput = Invoke-HookDryRun -EventName "Interrupt"
    $expectedInterruptTitle = '"Codex \u4efb\u52a1\u5df2\u4e2d\u65ad"' | ConvertFrom-Json
    if (($interruptOutput | ConvertFrom-Json).title -ne $expectedInterruptTitle) {
        throw "Interrupt must create a time-sensitive Bark notification."
    }

    if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName "UnsupportedHook"))) {
        throw "Unsupported hook events must not send Bark notifications."
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

    $hooksExamplePath = Join-Path (Split-Path $PSScriptRoot -Parent) "hooks.example.json"
    $hooksExample = Get-Content -LiteralPath $hooksExamplePath -Raw | ConvertFrom-Json
    foreach ($requiredEvent in @("PermissionRequest", "Stop", "Interrupt")) {
        if ($null -eq $hooksExample.hooks.$requiredEvent) {
            throw "hooks.example.json must configure $requiredEvent."
        }
    }

    $testDeviceKey = "test-device-key-12345"
    $testSecureKey = ConvertTo-SecureString -String $testDeviceKey -AsPlainText -Force
    $testEncryptedKey = ConvertFrom-SecureString -SecureString $testSecureKey
    $secretDirectory = Join-Path $testProfile ".codex\secrets"
    New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $secretDirectory "bark-device-key.dpapi") -Value $testEncryptedKey -Encoding ASCII
    $permissionStatePath = Join-Path $testProfile ".codex\state\permission-test.json"
    $httpCapture = @{ Count = 0 }
    function Invoke-RestMethod {
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec)
        $httpCapture.Count++
        return @{ code = 200 }
    }
    foreach ($tool in @("Bash", "apply_patch", "Bash")) {
        $approvalPayload = @{
            hook_event_name = "PermissionRequest"
            session_id = "approval-session"
            turn_id = "turn-$tool"
            tool_name = $tool
            tool_input = @{ description = "Request $tool" }
        } | ConvertTo-Json -Depth 5 -Compress
        & $scriptPath -NotificationJson $approvalPayload -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    }
    if ($httpCapture.Count -ne 1) {
        throw "A burst of different approval tools in one session must send only one notification."
    }
    $otherSession = @{ hook_event_name = "PermissionRequest"; session_id = "other-session"; tool_name = "Bash" } | ConvertTo-Json
    & $scriptPath -NotificationJson $otherSession -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    $stopDuringCooldown = @{ hook_event_name = "Stop"; session_id = "approval-session"; turn_id = "stop-turn" } | ConvertTo-Json
    & $scriptPath -NotificationJson $stopDuringCooldown -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    if ($httpCapture.Count -ne 3) {
        throw "Permission cooldown must not suppress another session or Stop notifications."
    }
    $permissionState = Get-Content -LiteralPath $permissionStatePath -Raw | ConvertFrom-Json
    foreach ($entry in $permissionState.entries) {
        if ($entry.key -eq "permission:approval-session") {
            $entry.sent_at = [DateTimeOffset]::UtcNow.AddSeconds(-301).ToString("o")
        }
    }
    $permissionState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $permissionStatePath -Encoding UTF8
    & $scriptPath -NotificationJson $approvalPayload -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    if ($httpCapture.Count -ne 4) {
        throw "A new approval after the five-minute cooldown must notify again."
    }
    Remove-Item Function:\Invoke-RestMethod
    . $scriptPath `
        -NotificationJson (@{ type = "unsupported-test-event" } | ConvertTo-Json -Compress) `
        -DryRun `
        -LogPath $testLogPath
    if ((Unprotect-BarkDeviceKey -EncryptedKey $testEncryptedKey) -ne $testDeviceKey) {
        throw "The notifier must decrypt its DPAPI secret without loading PowerShell.Security in the hook process."
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
