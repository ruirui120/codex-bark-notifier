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
    param(
        [string]$EventName,
        [hashtable]$ExtraFields,
        [switch]$InferReviewer,
        [long]$DurationMs = 300000,
        [int]$MinimumDurationSeconds = 180
    )

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
        -DurationMsOverride $DurationMs `
        -MinimumDurationSeconds $MinimumDurationSeconds `
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
    $fixtureDirectory = Join-Path $testProfile ".codex\sessions\2026\09\10"
    New-Item -ItemType Directory -Force -Path $fixtureDirectory | Out-Null
    $env:USERPROFILE = $testProfile
    foreach ($mainThread in @("test-thread", "approval-session")) {
        $mainMetadata = @{ type = "session_meta"; payload = @{ id = $mainThread; source = "vscode" } } |
            ConvertTo-Json -Depth 5 -Compress
        Set-Content -LiteralPath (Join-Path $fixtureDirectory "rollout-$mainThread.jsonl") -Encoding UTF8 -Value $mainMetadata
    }

    # Ephemeral desktop helpers can emit Stop without ever writing a rollout.
    # Only confirmed main-session metadata can justify a lifecycle reminder.
    foreach ($unconfirmedSession in @(
        @{ name = "missing-metadata"; metadata = $null },
        @{ name = "corrupt-metadata"; metadata = '{"type":"session_meta","payload":' },
        @{ name = "unknown-source"; metadata = @{ type = "session_meta"; payload = @{ id = "unknown-source"; source = "future-internal-worker" } } },
        @{ name = "object-source"; metadata = @{ type = "session_meta"; payload = @{ id = "object-source"; source = @{ internal = "worker" } } } },
        @{ name = "mismatched-id"; metadata = @{ type = "session_meta"; payload = @{ id = "some-other-main-thread"; source = "vscode" } } },
        @{ name = "empty-id"; metadata = @{ type = "session_meta"; payload = @{ id = ""; source = "vscode" } } }
    )) {
        $unconfirmedThread = $unconfirmedSession.name
        if ($null -ne $unconfirmedSession.metadata) {
            $metadataText = $unconfirmedSession.metadata
            if ($metadataText -isnot [string]) {
                $metadataText = $metadataText | ConvertTo-Json -Depth 8 -Compress
            }
            Set-Content -LiteralPath (Join-Path $fixtureDirectory "rollout-$unconfirmedThread.jsonl") -Encoding UTF8 -Value $metadataText
        }
        foreach ($unconfirmedEvent in @("Stop", "Interrupt", "SessionEnd")) {
            $unconfirmedOutput = Invoke-HookDryRun -EventName $unconfirmedEvent -ExtraFields @{
                session_id = $unconfirmedThread; turn_id = "unconfirmed-turn"
            }
            if (-not [string]::IsNullOrWhiteSpace($unconfirmedOutput)) {
                throw "An unconfirmed session ($unconfirmedThread) must not send a $unconfirmedEvent reminder."
            }
        }
        $unconfirmedPayload = @{ type = "agent-turn-complete"; 'thread-id' = $unconfirmedThread; 'turn-id' = "unconfirmed-turn" } |
            ConvertTo-Json -Compress
        if (-not [string]::IsNullOrWhiteSpace((Invoke-DryRun -DurationMs 300000 -EventPayload $unconfirmedPayload))) {
            throw "An unconfirmed session ($unconfirmedThread) must not send a legacy completion reminder."
        }
    }

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
        throw "A confirmed main Stop hook above the duration threshold must create a Bark notification."
    }

    foreach ($timedEvent in @("Stop", "Interrupt")) {
        foreach ($shortDuration in @(0, 179999)) {
            if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName $timedEvent -DurationMs $shortDuration))) {
                throw "A main $timedEvent at $shortDuration ms must preserve the three-minute minimum."
            }
        }
        foreach ($eligibleDuration in @(180000, 180001)) {
            if ([string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName $timedEvent -DurationMs $eligibleDuration))) {
                throw "A main $timedEvent at $eligibleDuration ms must notify at or above the three-minute minimum."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName $timedEvent -DurationMs -1))) {
            throw "A main $timedEvent without any matching duration evidence must not invent an eligible duration."
        }
        if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName $timedEvent -DurationMs 300000 -MinimumDurationSeconds 600))) {
            throw "A main $timedEvent must honor a larger configured minimum duration."
        }
        if ([string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName $timedEvent -DurationMs 120000 -MinimumDurationSeconds 120))) {
            throw "A main $timedEvent must honor a smaller configured minimum duration."
        }
    }

    & {
        $stopPayload = @{
            hook_event_name = "Stop"
            session_id = "test-thread"
            turn_id = "missing-secret-turn"
        } | ConvertTo-Json -Compress
        $hookResponse = $stopPayload | & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $scriptPath `
            -DurationMsOverride 300000 `
            -LogPath $testLogPath `
            -StatePath (Join-Path $testProfile ".codex\state\bark-notifier.json")
        if (([string]($hookResponse -join "`n")).Trim() -ne "{}") {
            throw "A Stop hook must return valid JSON even when Bark cannot be sent."
        }
    }

    $permissionOutput = Invoke-HookDryRun -EventName "PermissionRequest" -DurationMs 0 -ExtraFields @{
        tool_name = "Bash"
        tool_input = @{ description = "Allow network access" }
    }
    $permissionBody = $permissionOutput | ConvertFrom-Json
    $expectedPermissionTitle = '"Codex \u9700\u8981\u6743\u9650\u786e\u8ba4"' | ConvertFrom-Json
    if ($permissionBody.title -ne $expectedPermissionTitle -or $permissionBody.body -notmatch "Allow network access") {
        throw "PermissionRequest must identify a real approval immediately, even below the completion duration threshold."
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
    $fixturePath = Join-Path $fixtureDirectory "rollout-$fixtureThread.jsonl"
    $fixtureMetadata = @{ type = "session_meta"; payload = @{ id = $fixtureThread; source = "vscode" } } |
        ConvertTo-Json -Depth 5 -Compress
    $fixtureLine = @{
        timestamp = "2026-09-10T00:04:00Z"
        type = "event_msg"
        payload = @{
            type = "task_complete"
            turn_id = $fixtureTurn
            duration_ms = 240000
        }
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $fixturePath -Encoding ASCII -Value @($fixtureMetadata, $fixtureLine)
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
    foreach ($timedEvent in @("Stop", "Interrupt")) {
        $rolloutDurationOutput = Invoke-HookDryRun -EventName $timedEvent -DurationMs -1 -ExtraFields @{
            session_id = $fixtureThread; turn_id = $fixtureTurn
        }
        if ([string]::IsNullOrWhiteSpace($rolloutDurationOutput)) {
            throw "A main $timedEvent must read a qualifying duration from its matching rollout turn."
        }
        $unmatchedDurationOutput = Invoke-HookDryRun -EventName $timedEvent -DurationMs -1 -ExtraFields @{
            session_id = $fixtureThread; turn_id = "unmatched-duration-turn"
        }
        if (-not [string]::IsNullOrWhiteSpace($unmatchedDurationOutput)) {
            throw "A main $timedEvent must not reuse another turn's qualifying duration."
        }
    }

    # Stop may arrive before task_complete is persisted, while Codex still owns
    # the rollout file. Its own task_started event is sufficient time evidence.
    $activeThread = "active-main-thread"
    $activePath = Join-Path $fixtureDirectory "rollout-$activeThread.jsonl"
    $activeEvents = @(
        @{ type = "session_meta"; payload = @{ id = $activeThread; source = "vscode" } },
        @{ type = "event_msg"; payload = @{ type = "task_started"; turn_id = "active-main-turn"; started_at = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 240) } }
    ) | ForEach-Object { $_ | ConvertTo-Json -Depth 5 -Compress }
    Set-Content -LiteralPath $activePath -Encoding UTF8 -Value $activeEvents
    $activeWriter = [IO.File]::Open($activePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        foreach ($timedEvent in @("Stop", "Interrupt")) {
            $activeOutput = Invoke-HookDryRun -EventName $timedEvent -DurationMs -1 -ExtraFields @{
                session_id = $activeThread; turn_id = "active-main-turn"
            }
            if ([string]::IsNullOrWhiteSpace($activeOutput)) {
                throw "A main $timedEvent must derive elapsed time from task_started before task_complete is written."
            }
        }
    }
    finally { $activeWriter.Dispose() }

    # Long desktop transcripts often contain image data. Qualifying events near
    # the beginning must remain discoverable beyond a short tail window.
    $longThread = "long-transcript-main"
    $longPath = Join-Path $fixtureDirectory "rollout-$longThread.jsonl"
    $longLines = New-Object 'Collections.Generic.List[string]'
    foreach ($entry in @(
        @{ type = "session_meta"; payload = @{ id = $longThread; source = "vscode" } },
        @{ type = "event_msg"; payload = @{ type = "task_started"; turn_id = "long-active-turn"; started_at = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 240) } },
        @{ type = "event_msg"; payload = @{ type = "task_complete"; turn_id = "long-complete-turn"; duration_ms = 190000 } },
        @{ type = "event_msg"; payload = @{ type = "task_started"; turn_id = "missing-start-time" } },
        @{ type = "event_msg"; payload = @{ type = "task_started"; turn_id = "null-start-time"; started_at = $null } }
    )) { $longLines.Add(($entry | ConvertTo-Json -Depth 5 -Compress)) }
    foreach ($recordIndex in 1..650) {
        $longLines.Add((@{ type = "response_item"; payload = @{ type = "message"; content = "unrelated message $recordIndex" } } |
            ConvertTo-Json -Depth 5 -Compress))
    }
    $longLines.Add((@{ type = "response_item"; payload = @{ type = "image"; content = ("x" * 1048576) } } |
        ConvertTo-Json -Depth 5 -Compress))
    $longLines.Add((@{ type = "event_msg"; payload = @{ type = "task_complete"; turn_id = "unrelated-long-turn"; duration_ms = 900000 } } |
        ConvertTo-Json -Depth 5 -Compress))
    Set-Content -LiteralPath $longPath -Encoding UTF8 -Value $longLines
    foreach ($longTurn in @("long-active-turn", "long-complete-turn")) {
        $longFields = @{ session_id = $longThread; turn_id = $longTurn }
        if ([string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName "Stop" -DurationMs -1 -ExtraFields $longFields))) {
            throw "Long transcripts must retain qualifying start/complete evidence before the last 600 records ($longTurn)."
        }
        if (-not [string]::IsNullOrWhiteSpace((Invoke-HookDryRun -EventName "Stop" -DurationMs -1 -MinimumDurationSeconds 300 -ExtraFields $longFields))) {
            throw "Long transcripts must use the matching turn duration, not another turn's larger duration ($longTurn)."
        }
    }
    foreach ($invalidStartTurn in @("missing-start-time", "null-start-time")) {
        $invalidStartOutput = Invoke-HookDryRun -EventName "Stop" -DurationMs -1 -ExtraFields @{
            session_id = $longThread; turn_id = $invalidStartTurn
        }
        if (-not [string]::IsNullOrWhiteSpace($invalidStartOutput)) {
            throw "A task_started event with $invalidStartTurn must remain unknown instead of treating the start as the Unix epoch."
        }
    }

    # Desktop's legacy notify callback also fires when an internal child finishes.
    # A missing task name is not enough to distinguish children from main tasks.
    foreach ($sessionSource in @(
        @{ subagent = @{ thread_spawn = @{ parent_thread_id = $fixtureThread; depth = 1 } } },
        "subagent",
        "vscode", "cli", "exec", "appServer", "app_server"
    )) {
        $sourceThread = "source-fixture-thread"
        $sourcePath = Join-Path $fixtureDirectory "rollout-$sourceThread.jsonl"
        $sourceMeta = @{ type = "session_meta"; payload = @{ id = $sourceThread; source = $sessionSource } } |
            ConvertTo-Json -Depth 8 -Compress
        Set-Content -LiteralPath $sourcePath -Encoding UTF8 -Value $sourceMeta
        $sourcePayload = @{ type = "agent-turn-complete"; 'thread-id' = $sourceThread; 'turn-id' = "source-turn" } |
            ConvertTo-Json -Compress
        $sourceWriter = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            $sourceOutput = Invoke-DryRun -DurationMs 300000 -EventPayload $sourcePayload
            if ($sessionSource -is [string] -and $sessionSource -ne "subagent") {
                if ([string]::IsNullOrWhiteSpace($sourceOutput)) {
                    throw "A real main task must still notify, even without an indexed task name."
                }
                foreach ($mainEvent in @("Stop", "Interrupt", "SessionEnd")) {
                    $mainHookOutput = Invoke-HookDryRun -EventName $mainEvent -ExtraFields @{
                        session_id = $sourceThread; turn_id = "source-turn"
                    }
                    if ([string]::IsNullOrWhiteSpace($mainHookOutput)) {
                        throw "A confirmed $sessionSource main task must still send $mainEvent without an indexed task name."
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($sourceOutput)) {
                throw "An internal subagent completion must not claim the main task has finished."
            }
            else {
                foreach ($childEvent in @("Stop", "Interrupt", "SessionEnd")) {
                    $childHookOutput = Invoke-HookDryRun -EventName $childEvent -ExtraFields @{
                        session_id = $sourceThread; turn_id = "source-turn"
                    }
                    if (-not [string]::IsNullOrWhiteSpace($childHookOutput)) {
                        throw "An internal subagent $childEvent must not claim the main task has stopped."
                    }
                }
                $childPermissionOutput = Invoke-HookDryRun -EventName "PermissionRequest" -ExtraFields @{
                    session_id = $sourceThread; turn_id = "source-turn"; tool_name = "Bash"
                }
                if ([string]::IsNullOrWhiteSpace($childPermissionOutput)) {
                    throw "A child request routed to a human must still notify; filtering completion must not hide real approvals."
                }
            }
        }
        finally { $sourceWriter.Dispose() }
    }
    $sourceLogs = Get-Content -LiteralPath $testLogPath -Encoding UTF8
    if (-not ($sourceLogs -match 'complete\s+ignored\s+build=\S+ origin=notify thread=source-fixture-thread turn=source-turn .*subagent')) {
        throw "Suppressed child completions must log their build, callback origin, thread and turn."
    }

    $archivedThread = "archived-child-thread"
    $archivedDirectory = Join-Path $testProfile ".codex\archived_sessions"
    New-Item -ItemType Directory -Force -Path $archivedDirectory | Out-Null
    $archivedMeta = @{ type = "session_meta"; payload = @{ id = $archivedThread; source = @{ subagent = @{ thread_spawn = @{ parent_thread_id = $fixtureThread } } } } } |
        ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath (Join-Path $archivedDirectory "rollout-$archivedThread.jsonl") -Encoding UTF8 -Value $archivedMeta
    $archivedPayload = @{ type = "agent-turn-complete"; 'thread-id' = $archivedThread; 'turn-id' = "archived-child-turn" } |
        ConvertTo-Json -Compress
    if (-not [string]::IsNullOrWhiteSpace((Invoke-DryRun -DurationMs 300000 -EventPayload $archivedPayload))) {
        throw "An archived child must still be recognized when its legacy callback arrives late."
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
    & $scriptPath -NotificationJson $stopAfterApproval -DurationMsOverride 300000 -LogPath $testLogPath -StatePath $permissionStatePath | Out-Null
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
