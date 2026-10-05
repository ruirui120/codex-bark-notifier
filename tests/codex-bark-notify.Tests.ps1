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
    param([string]$EventName, [hashtable]$ExtraFields, [switch]$InferReviewer)

    $hookPayload = @{
        hook_event_name = $EventName
        session_id = "test-thread"
        turn_id = "test-turn"
        permission_mode = "default"
    }
    if ($EventName -eq "PermissionRequest" -and -not $InferReviewer) {
        $hookPayload.approvals_reviewer = "user"
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
        approvals_reviewer = "user"
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

    $approvalRolloutPath = Join-Path $fixtureDirectory "rollout-approval-rollout-thread.jsonl"
    $approvalContexts = @(
        @{ type = "turn_context"; payload = @{ turn_id = "old-manual-turn"; approvals_reviewer = "user" } },
        @{ type = "turn_context"; payload = @{ turn_id = "current-auto-turn"; approvals_reviewer = "auto_review" } },
        @{ type = "turn_context"; payload = @{ turn_id = "legacy-manual-turn"; approval_policy = "on-request" } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    Set-Content -LiteralPath $approvalRolloutPath -Encoding UTF8 -Value $approvalContexts

    $automaticOutput = Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields @{
        session_id = "approval-rollout-thread"
        turn_id = "current-auto-turn"
        tool_name = "Bash"
        tool_input = @{ command = "git push" }
    }
    if (-not [string]::IsNullOrWhiteSpace($automaticOutput)) {
        throw "The matching current auto_review turn must suppress permission reminders even after an older manual turn."
    }
    $manualOutput = Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields @{
        session_id = "approval-rollout-thread"
        turn_id = "old-manual-turn"
        tool_name = "Bash"
    }
    if ([string]::IsNullOrWhiteSpace($manualOutput)) {
        throw "A matching manual reviewer turn must retain genuine user approval reminders."
    }
    $rolloutWriter = [IO.File]::Open($approvalRolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $lockedRolloutOutput = Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields @{
            session_id = "approval-rollout-thread"
            turn_id = "old-manual-turn"
            tool_name = "Bash"
            tool_input = @{ command = "A real request while Codex is writing the rollout" }
        }
        if ([string]::IsNullOrWhiteSpace($lockedRolloutOutput)) {
            throw "The hook must read effective approval settings while the active rollout is open for writing."
        }
    }
    finally {
        $rolloutWriter.Dispose()
    }
    $legacyManualOutput = Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields @{
        session_id = "approval-rollout-thread"
        turn_id = "legacy-manual-turn"
        tool_name = "Bash"
    }
    if ([string]::IsNullOrWhiteSpace($legacyManualOutput)) {
        throw "A matched legacy turn_context without approvals_reviewer must retain user approval reminders."
    }
    foreach ($fields in @(
        @{ session_id = "missing-context-thread"; turn_id = "missing-context-turn"; tool_name = "Bash" },
        @{ session_id = "approval-rollout-thread"; turn_id = "unmatched-turn"; tool_name = "Bash" }
    )) {
        if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields $fields))) {
            throw "Without a matching approval context, the hook must not invent a request waiting for the user."
        }
    }
    foreach ($tool in @("mcp__cua_repl__js", "mcp__computer_use__click")) {
        $uiOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
            approvals_reviewer = "auto_review"
            tool_name = $tool
        }
        if (-not [string]::IsNullOrWhiteSpace($uiOutput)) {
            throw "Computer-use PermissionRequest events handled by auto_review must not send false user reminders."
        }
        $manualUiOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
            approvals_reviewer = "user"
            tool_name = $tool
        }
        if ([string]::IsNullOrWhiteSpace($manualUiOutput)) {
            throw "Computer-use requests with a manual user reviewer must still notify."
        }
    }
    $preferredTranscript = Join-Path $fixtureDirectory "explicit-transcript.jsonl"
    $preferredContext = @{
        type = "turn_context"
        payload = @{ turn_id = "current-auto-turn"; approvals_reviewer = "user" }
    } | ConvertTo-Json -Depth 5 -Compress
    Set-Content -LiteralPath $preferredTranscript -Encoding UTF8 -Value $preferredContext
    $preferredOutput = Invoke-HookDryRun -EventName "PermissionRequest" -InferReviewer -ExtraFields @{
        session_id = "approval-rollout-thread"
        turn_id = "current-auto-turn"
        transcript_path = $preferredTranscript
        tool_name = "Bash"
    }
    if ([string]::IsNullOrWhiteSpace($preferredOutput)) {
        throw "An explicit transcript_path must be read before searching by session id."
    }
    $explicitAutomaticOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
        approvals_reviewer = "auto_review"
        transcript_path = $preferredTranscript
        turn_id = "current-auto-turn"
        tool_name = "Bash"
    }
    if (-not [string]::IsNullOrWhiteSpace($explicitAutomaticOutput)) {
        throw "An explicit hook reviewer must take precedence over the transcript reviewer."
    }
    $guardianOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
        approvals_reviewer = "guardian_subagent"
        tool_name = "Bash"
    }
    if (-not [string]::IsNullOrWhiteSpace($guardianOutput)) {
        throw "The guardian_subagent reviewer alias must suppress automatically handled approvals."
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
    foreach ($request in @(
        @{ tool = "Bash"; command = "git push" },
        @{ tool = "apply_patch"; command = "*** Update File: example.txt" }
    )) {
        $approvalPayload = @{
            hook_event_name = "PermissionRequest"
            session_id = "approval-session"
            turn_id = "approval-turn"
            approvals_reviewer = "user"
            tool_name = $request.tool
            tool_input = @{ description = "A real user approval"; command = $request.command }
        } | ConvertTo-Json -Depth 5 -Compress
        & $scriptPath -NotificationJson $approvalPayload -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    }
    if ($httpCapture.Count -ne 2) {
        throw "Distinct requests that genuinely need a user must both notify, even within the same turn."
    }
    & $scriptPath -NotificationJson $approvalPayload -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    if ($httpCapture.Count -ne 2) {
        throw "Replaying the exact same approval request must not notify twice."
    }
    $otherSession = @{ hook_event_name = "PermissionRequest"; session_id = "other-session"; approvals_reviewer = "user"; tool_name = "Bash" } | ConvertTo-Json
    & $scriptPath -NotificationJson $otherSession -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    $stopAfterApproval = @{ hook_event_name = "Stop"; session_id = "approval-session"; turn_id = "stop-turn" } | ConvertTo-Json
    & $scriptPath -NotificationJson $stopAfterApproval -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    if ($httpCapture.Count -ne 4) {
        throw "Permission deduplication must not suppress another session or Stop notifications."
    }
    foreach ($tool in @("Bash", "apply_patch", "mcp__github__create_pull_request")) {
        $automaticPayload = @{
            hook_event_name = "PermissionRequest"
            session_id = "automatic-session"
            turn_id = "automatic-turn"
            approvals_reviewer = "auto_review"
            tool_name = $tool
            tool_input = @{ command = "Automatic approval for $tool" }
        } | ConvertTo-Json -Depth 5 -Compress
        & $scriptPath -NotificationJson $automaticPayload -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
    }
    if ($httpCapture.Count -ne 4) {
        throw "Automatic reviewer requests must be suppressed before sending Bark."
    }
    Remove-Item Function:\Invoke-RestMethod
    . $scriptPath `
        -NotificationJson (@{ type = "unsupported-test-event" } | ConvertTo-Json -Compress) `
        -DryRun `
        -LogPath $testLogPath
    if ((Unprotect-BarkDeviceKey -EncryptedKey $testEncryptedKey) -ne $testDeviceKey) {
        throw "The notifier must decrypt its DPAPI secret without loading PowerShell.Security in the hook process."
    }

    $quotaFixture = [pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 300 }
        secondary = [pscustomobject]@{ usedPercent = 73.5; windowDurationMins = 10080 }
    }
    $quotaText = Format-CodexQuota -RateLimits $quotaFixture
    if ($quotaText -notmatch '75%' -or $quotaText -notmatch '26.5%') {
        throw "Quota text must show remaining percentages, not used percentages."
    }
    $swappedQuota = [pscustomobject]@{ primary = $quotaFixture.secondary; secondary = $quotaFixture.primary }
    if ((Format-CodexQuota -RateLimits $swappedQuota) -ne $quotaText) {
        throw "Quota windows must be identified by duration, not primary/secondary position."
    }
    $unknownText = '"\u6682\u4e0d\u53ef\u7528"' | ConvertFrom-Json
    $missingQuotaText = Format-CodexQuota -RateLimits $null
    if (($missingQuotaText -split [regex]::Escape($unknownText)).Count -ne 3) {
        throw "Unavailable quota must be explicit for both windows, never reported as zero."
    }
    foreach ($invalidValue in @($null, "invalid", "NaN")) {
        $badQuota = @{ primary = @{ usedPercent = $invalidValue; windowDurationMins = 300 } }
        if ((Format-CodexQuota -RateLimits $badQuota) -ne $missingQuotaText) {
            throw "Invalid quota data must remain unavailable."
        }
    }
    $expiredQuota = @{ primary = @{ usedPercent = 25; windowDurationMins = 300; resetsAt = 1 } }
    if ((Format-CodexQuota -RateLimits $expiredQuota) -ne $missingQuotaText) {
        throw "An expired quota window must not show a stale percentage."
    }
    $zeroUsed = @{ primary = @{ usedPercent = 0; windowDurationMins = 300 } }
    if ((Format-CodexQuota -RateLimits $zeroUsed) -notmatch '100%') {
        throw "Zero usage must yield 100 percent remaining."
    }

    # Exercise the outgoing UTF-8 payload, with quota RPC and Bark HTTP mocked.
    $DryRun = $false
    $httpCapture = @{ Count = 0; Payload = $null; QuotaCalls = 0 }
    function Get-CodexRateLimits {
        param($TimeoutMilliseconds)
        $httpCapture.QuotaCalls++
        return $quotaFixture
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $ContentType, $Body, $TimeoutSec)
        $httpCapture.Count++
        $httpCapture.Payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        return @{ code = 200 }
    }
    foreach ($eventName in @("permission", "stop", "interrupt", "session-end", "complete")) {
        Send-BarkNotification -EventName $eventName -Title "Test" -Body $expectedTaskName -Level "active" -DedupeKey "" -LogDetail "quota-test" | Out-Null
        if ($httpCapture.Payload.body -notmatch '75%' -or $httpCapture.Payload.body -notmatch '26.5%' -or
            $httpCapture.Payload.body -notmatch [regex]::Escape($expectedTaskName)) {
            throw "Every event must preserve Chinese text and include both quotas in its actual HTTP body."
        }
    }
    $quotaFixture = $null
    Send-BarkNotification -EventName "stop" -Title "Test" -Body "Test" -Level "active" -DedupeKey "" -LogDetail "quota-unavailable" | Out-Null
    if ($httpCapture.Payload.body -notmatch [regex]::Escape($unknownText) -or $httpCapture.Count -ne 6) {
        throw "Quota failure must not prevent Bark notification delivery."
    }
    $StatePath = $permissionStatePath
    Send-BarkNotification -EventName "stop" -Title "Test" -Body "Test" -Level "active" -DedupeKey "quota-repeat" -LogDetail "quota-test" | Out-Null
    Send-BarkNotification -EventName "stop" -Title "Test" -Body "Test" -Level "active" -DedupeKey "quota-repeat" -LogDetail "quota-test" | Out-Null
    if ($httpCapture.Count -ne 7 -or $httpCapture.QuotaCalls -ne 7) {
        throw "A suppressed duplicate must not fetch quota or send another notification."
    }
    Remove-Item Function:\Invoke-RestMethod

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
