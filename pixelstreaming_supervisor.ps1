param(
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoRoot = $script:ScriptRoot

$Config = [ordered]@{
    PollSeconds = 5

    # Signalling/TURN
    StartSignalling = $true
    SignallingStartCooldownSeconds = 30
    SignallingWorkingDir = (Join-Path $script:RepoRoot 'SignallingWebServer\platform_scripts\cmd')
    SignallingScript = 'start_with_turn.bat'
    # IMPORTANT: Server args must be passed after "--" for these Epic scripts.
    # Use a non-default streamer port to avoid conflicts with other local services using 8888.
    SignallingArgs = '-- --rest_api --player_port 1025 --streamer_port 18888'

    # REST API used for player/streamer counts (requires --rest_api)
    SignallingStatusUrl = 'http://127.0.0.1:1025/api/status'
    IgnoreSelfSignedCert = $true

    # Optional SFU
    StartSFU = $false
    SFUStartCooldownSeconds = 30
    SFUWorkingDir = (Join-Path $script:RepoRoot 'SFU\platform_scripts\cmd')
    SFUScript = 'run_local.bat' # or run_cloud.bat
    SFUArgs = ''

    # Port conflict protection (player + dedicated streamer port)
    CheckPortConflicts = $true
    ConflictPorts = @(1025, 18888)
    AutoKillConflictingListeners = $false
    AllowedListenerProcessNames = @('node', 'System', 'Idle')

    # Tailscale / Funnel checks
    CheckTailscale = $true
    TailscaleExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
    TailscaleRepairCooldownSeconds = 60
    # Optional extra checks/repairs. Fill these with your exact commands if desired.
    # Examples (replace with your real setup):
    #   $Config.TailscaleFunnelHealthCheckCmd = '"C:\Program Files\Tailscale\tailscale.exe" funnel status'
    #   $Config.TailscaleRepairCommands = @(
    #       '"C:\Program Files\Tailscale\tailscale.exe" serve status',
    #       '"C:\Program Files\Tailscale\tailscale.exe" funnel status'
    #   )
    # Pixel Streaming player page is served locally by SignallingWebServer.
    # Your setup exposes local HTTP :1025 through a public HTTPS Funnel on port 443.
    TailscaleFunnelHealthCheckCmd = '"C:\Program Files\Tailscale\tailscale.exe" funnel status'
    TailscaleRepairCommands = @(
        '"C:\Program Files\Tailscale\tailscale.exe" funnel --yes --bg --https=443 1025'
    )

    # Streamer lifecycle (on-demand + idle shutdown)
    StartStreamerOnDemand = $true
    StopStreamerOnIdle = $true
    StreamerStartCooldownSeconds = 30
    StreamerStopGraceSeconds = 10
    IdleTimeoutSeconds = 600       # 10 minutes
    MinStreamerUpSeconds = 120     # avoid flapping on short disconnects
    StreamerExePath = 'C:\v221\Windows\BEN221.exe'
    # BEN221.exe launches the actual game process BEN200 on this machine.
    StreamerProcessName = 'BEN200'
    StreamerStartupSettleSeconds = 5
    StreamerArgs = '-PixelStreamingURL=ws://127.0.0.1:18888 -RenderOffScreen'
}

$State = [ordered]@{
    LastSignallingStartAttempt = [datetime]::MinValue
    LastSFUStartAttempt = [datetime]::MinValue
    LastTailscaleRepairAttempt = [datetime]::MinValue
    LastStreamerStartAttempt = [datetime]::MinValue
    LastPlayerSeenAt = (Get-Date)
    SignallingConsolePid = $null
    SFUConsolePid = $null
    StreamerPid = $null
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$stamp][$Level] $Message"
}

function Invoke-NativeCommandNoThrow {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    $hadNativePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hadNativePref) {
        $previousNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        try {
            $stdout = & $FilePath @Arguments 2>$null
            $exitCode = $LASTEXITCODE
        } catch {
            $nativeExitEx = $null
            if ($_.Exception -is [System.Management.Automation.NativeCommandExitException]) {
                $nativeExitEx = $_.Exception
            } elseif ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException -is [System.Management.Automation.NativeCommandExitException]) {
                $nativeExitEx = $_.Exception.InnerException
            }

            if ($nativeExitEx -or ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0)) {
                $stdout = @()
                if ($null -ne $nativeExitEx -and $null -ne $nativeExitEx.ExitCode) {
                    $exitCode = [int]$nativeExitEx.ExitCode
                } else {
                    $exitCode = [int]$LASTEXITCODE
                }
            } else {
                throw
            }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut = @($stdout)
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hadNativePref) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePref
        }
    }
}

function Test-CooldownElapsed {
    param(
        [Parameter(Mandatory = $true)][datetime]$Last,
        [Parameter(Mandatory = $true)][int]$CooldownSeconds
    )

    if ($CooldownSeconds -le 0) { return $true }
    return (((Get-Date) - $Last).TotalSeconds -ge $CooldownSeconds)
}

function Invoke-CurlJson {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw 'curl.exe was not found. Install/enable curl.exe or adapt the script to use Invoke-RestMethod.'
    }

    $args = @('-sS', '-L')
    if ($Config.IgnoreSelfSignedCert) {
        $args += '-k'
    }
    $args += $Url

    $result = Invoke-NativeCommandNoThrow -FilePath $curl.Source -Arguments $args
    $raw = @($result.StdOut)
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join ''))) {
        return $null
    }

    $rawText = ($raw -join [Environment]::NewLine)

    try {
        return ($rawText | ConvertFrom-Json)
    } catch {
        $preview = $rawText
        if ($preview.Length -gt 160) {
            $preview = $preview.Substring(0, 160) + '...'
        }
        if ($rawText -match 'Cannot GET /api/status') {
            Write-Log "A web server is responding on the player port, but the REST API route /api/status is not enabled. This usually means SignallingWebServer is running without --rest_api (or another app is using port 1025)." 'WARN'
        }
        Write-Log "Failed to parse JSON from $Url. Response preview: $preview" 'WARN'
        return $null
    }
}

function Invoke-CmdCapture {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine
    )

    $result = Invoke-NativeCommandNoThrow -FilePath 'cmd.exe' -Arguments @('/c', $CommandLine)
    $output = @($result.StdOut)
    $exitCode = $result.ExitCode

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($output) -join [Environment]::NewLine)
    }
}

function Get-ListenerProcessesByPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port
    )

    $rows = @()

    try {
        $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        foreach ($conn in $connections) {
            $procId = [int]$conn.OwningProcess
            $procName = ''
            try {
                $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
            } catch {
                $procName = '<unknown>'
            }

            $rows += [pscustomobject]@{
                Port = $Port
                PID = $procId
                ProcessName = $procName
            }
        }
    } catch {
        $netstat = & netstat.exe -ano -p tcp | Select-String -Pattern "LISTENING" | Select-String -Pattern "[:.]$Port\s"
        foreach ($line in $netstat) {
            $text = $line.ToString().Trim()
            if ($text -match '\s+(\d+)$') {
                $procId = [int]$Matches[1]
                $procName = ''
                try {
                    $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
                } catch {
                    $procName = '<unknown>'
                }

                $rows += [pscustomobject]@{
                    Port = $Port
                    PID = $procId
                    ProcessName = $procName
                }
            }
        }
    }

    return @($rows | Sort-Object PID -Unique)
}

function Resolve-PortConflicts {
    if (-not $Config.CheckPortConflicts) { return }

    foreach ($port in $Config.ConflictPorts) {
        $listeners = @(Get-ListenerProcessesByPort -Port $port)
        if ($listeners.Count -eq 0) { continue }

        foreach ($listener in $listeners) {
            $allowed = $Config.AllowedListenerProcessNames -contains $listener.ProcessName
            if ($allowed) { continue }

            Write-Log "Port $port is in use by PID $($listener.PID) ($($listener.ProcessName))." 'WARN'
            if ($Config.AutoKillConflictingListeners) {
                try {
                    Stop-Process -Id $listener.PID -Force -ErrorAction Stop
                    Write-Log "Killed PID $($listener.PID) on port $port." 'WARN'
                } catch {
                    Write-Log "Failed to kill PID $($listener.PID): $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}

function Test-SignallingApi {
    $status = Invoke-CurlJson -Url $Config.SignallingStatusUrl
    if (-not $status) { return $null }

    if ($null -ne $status.player_count -and [int]$status.player_count -gt 0) {
        $State.LastPlayerSeenAt = Get-Date
    }

    return $status
}

function Test-TrackedProcessAlive {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$PidValue
    )

    if (-not $PidValue) { return $false }

    try {
        $null = Get-Process -Id ([int]$PidValue) -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Start-SignallingStack {
    $scriptPath = Join-Path $Config.SignallingWorkingDir $Config.SignallingScript
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Log "Signalling script not found: $scriptPath" 'ERROR'
        return
    }

    $cmdLine = if ([string]::IsNullOrWhiteSpace($Config.SignallingArgs)) {
        "call `"$scriptPath`""
    } else {
        "call `"$scriptPath`" $($Config.SignallingArgs)"
    }

    Write-Log "Starting signalling/TURN via $($Config.SignallingScript) ..."
    $proc = Start-Process -FilePath 'cmd.exe' -WorkingDirectory $Config.SignallingWorkingDir -ArgumentList '/k', $cmdLine -PassThru
    $State.SignallingConsolePid = $proc.Id
    $State.LastSignallingStartAttempt = Get-Date
}

function Ensure-SignallingAvailable {
    $status = Test-SignallingApi
    if ($status) { return $status }

    if (-not $Config.StartSignalling) { return $null }

    if (-not (Test-CooldownElapsed -Last $State.LastSignallingStartAttempt -CooldownSeconds $Config.SignallingStartCooldownSeconds)) {
        return $null
    }

    if (Test-TrackedProcessAlive -PidValue $State.SignallingConsolePid) {
        return $null
    }

    Resolve-PortConflicts
    Start-SignallingStack
    return $null
}

function Start-SFUIfNeeded {
    if (-not $Config.StartSFU) { return }

    if (Test-TrackedProcessAlive -PidValue $State.SFUConsolePid) {
        return
    }

    if (-not (Test-CooldownElapsed -Last $State.LastSFUStartAttempt -CooldownSeconds $Config.SFUStartCooldownSeconds)) {
        return
    }

    $scriptPath = Join-Path $Config.SFUWorkingDir $Config.SFUScript
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Log "SFU script not found: $scriptPath" 'ERROR'
        return
    }

    $cmdLine = if ([string]::IsNullOrWhiteSpace($Config.SFUArgs)) {
        "call `"$scriptPath`""
    } else {
        "call `"$scriptPath`" $($Config.SFUArgs)"
    }

    Write-Log "Starting SFU via $($Config.SFUScript) ..."
    $proc = Start-Process -FilePath 'cmd.exe' -WorkingDirectory $Config.SFUWorkingDir -ArgumentList '/k', $cmdLine -PassThru
    $State.SFUConsolePid = $proc.Id
    $State.LastSFUStartAttempt = Get-Date
}

function Ensure-TailscaleHealthy {
    if (-not $Config.CheckTailscale) { return }

    if (-not (Test-Path -LiteralPath $Config.TailscaleExe)) {
        Write-Log "Tailscale executable not found: $($Config.TailscaleExe)" 'WARN'
        return
    }

    $healthy = $true

    try {
        $result = Invoke-NativeCommandNoThrow -FilePath $Config.TailscaleExe -Arguments @('status', '--json')
        $jsonText = @($result.StdOut) -join [Environment]::NewLine
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) {
            $healthy = $false
            Write-Log 'tailscale status --json failed.' 'WARN'
        } else {
            $ts = ($jsonText | ConvertFrom-Json)
            if ($ts.BackendState -ne 'Running') {
                $healthy = $false
                Write-Log "Tailscale backend state is '$($ts.BackendState)' (expected 'Running')." 'WARN'
            }
            if ($ts.Self -and ($null -ne $ts.Self.Online) -and (-not $ts.Self.Online)) {
                $healthy = $false
                Write-Log 'Tailscale is not online.' 'WARN'
            }
        }
    } catch {
        $healthy = $false
        Write-Log "Tailscale check failed: $($_.Exception.Message)" 'WARN'
    }

    if ($healthy -and -not [string]::IsNullOrWhiteSpace($Config.TailscaleFunnelHealthCheckCmd)) {
        $check = Invoke-CmdCapture -CommandLine $Config.TailscaleFunnelHealthCheckCmd
        if ($check.ExitCode -ne 0) {
            $healthy = $false
            Write-Log "Funnel health check failed (exit $($check.ExitCode))." 'WARN'
        }
    }

    if ($healthy) { return }

    if (-not (Test-CooldownElapsed -Last $State.LastTailscaleRepairAttempt -CooldownSeconds $Config.TailscaleRepairCooldownSeconds)) {
        return
    }

    $State.LastTailscaleRepairAttempt = Get-Date

    if ($Config.TailscaleRepairCommands.Count -eq 0) {
        Write-Log 'Tailscale unhealthy, but no repair commands are configured. Set TailscaleRepairCommands in the script.' 'WARN'
        return
    }

    foreach ($cmd in $Config.TailscaleRepairCommands) {
        Write-Log "Running Tailscale repair command: $cmd"
        $result = Invoke-CmdCapture -CommandLine $cmd
        if ($result.ExitCode -ne 0) {
            Write-Log "Repair command failed (exit $($result.ExitCode)). Output: $($result.Output)" 'WARN'
        }
    }
}

function Get-ConfiguredStreamerProcessName {
    if ($Config.Contains('StreamerProcessName') -and -not [string]::IsNullOrWhiteSpace($Config.StreamerProcessName)) {
        return $Config.StreamerProcessName
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.StreamerExePath)) {
        return [System.IO.Path]::GetFileNameWithoutExtension($Config.StreamerExePath)
    }
    return $null
}

function Get-ManagedStreamerProcess {
    if ($State.StreamerPid) {
        try {
            return (Get-Process -Id ([int]$State.StreamerPid) -ErrorAction Stop)
        } catch {
            $State.StreamerPid = $null
        }
    }

    $procName = Get-ConfiguredStreamerProcessName
    if ([string]::IsNullOrWhiteSpace($procName)) {
        return $null
    }

    try {
        $candidates = @(Get-Process -Name $procName -ErrorAction Stop)
        if ($candidates.Count -gt 0) {
            $proc = $candidates | Sort-Object StartTime -Descending | Select-Object -First 1
            $State.StreamerPid = $proc.Id
            return $proc
        }
    } catch {
        return $null
    }

    return $null
}

function Start-ManagedStreamer {
    if (-not $Config.StartStreamerOnDemand) { return }

    if ([string]::IsNullOrWhiteSpace($Config.StreamerExePath) -or $Config.StreamerExePath -like 'C:\Path\To\*') {
        Write-Log 'StreamerExePath is not configured yet. Set it in pixelstreaming_supervisor.ps1.' 'WARN'
        return
    }

    if (-not (Test-Path -LiteralPath $Config.StreamerExePath)) {
        Write-Log "Streamer executable not found: $($Config.StreamerExePath)" 'ERROR'
        return
    }

    if (-not (Test-CooldownElapsed -Last $State.LastStreamerStartAttempt -CooldownSeconds $Config.StreamerStartCooldownSeconds)) {
        return
    }

    $existing = Get-ManagedStreamerProcess
    if ($existing) { return }

    Write-Log "Starting streamer: $($Config.StreamerExePath)"
    $proc = if ([string]::IsNullOrWhiteSpace($Config.StreamerArgs)) {
        Start-Process -FilePath $Config.StreamerExePath -PassThru
    } else {
        Start-Process -FilePath $Config.StreamerExePath -ArgumentList $Config.StreamerArgs -PassThru
    }

    $State.StreamerPid = $proc.Id

    # Some packaged launchers spawn a differently-named child process (e.g. BEN221 -> BEN200).
    # Prefer tracking the runtime process if a process-name override is configured.
    $runtimeProcName = Get-ConfiguredStreamerProcessName
    $launchedProcName = [System.IO.Path]::GetFileNameWithoutExtension($Config.StreamerExePath)
    if (-not [string]::IsNullOrWhiteSpace($runtimeProcName) -and $runtimeProcName -ne $launchedProcName) {
        $settleSeconds = 0
        try { $settleSeconds = [int]$Config.StreamerStartupSettleSeconds } catch { $settleSeconds = 0 }
        if ($settleSeconds -gt 0) {
            Start-Sleep -Seconds $settleSeconds
        }

        try {
            $candidates = @(Get-Process -Name $runtimeProcName -ErrorAction Stop)
            if ($candidates.Count -gt 0) {
                $runtimeProc = $candidates | Sort-Object StartTime -Descending | Select-Object -First 1
                $State.StreamerPid = $runtimeProc.Id
                Write-Log "Tracking runtime streamer process '$runtimeProcName' PID $($runtimeProc.Id) (launcher PID was $($proc.Id))."
            }
        } catch {
            Write-Log "Started launcher PID $($proc.Id), but runtime process '$runtimeProcName' was not detected yet." 'WARN'
        }
    }

    $State.LastStreamerStartAttempt = Get-Date
}

function Stop-ManagedStreamer {
    param(
        [Parameter(Mandatory = $true)]$Process
    )

    Write-Log "Stopping streamer PID $($Process.Id) ..."

    $closed = $false
    try {
        if ($Process.MainWindowHandle -ne 0) {
            $null = $Process.CloseMainWindow()
            $closed = $Process.WaitForExit($Config.StreamerStopGraceSeconds * 1000)
        }
    } catch {
        $closed = $false
    }

    if (-not $closed) {
        $taskkill = Invoke-NativeCommandNoThrow -FilePath 'taskkill.exe' -Arguments @('/PID', "$($Process.Id)", '/T', '/F')
        if ($taskkill.ExitCode -ne 0) {
            try {
                Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to stop streamer PID $($Process.Id): $($_.Exception.Message)" 'ERROR'
                return
            }
        } else {
            Write-Log "taskkill terminated streamer tree for PID $($Process.Id)."
        }
    }

    # If the runtime process name differs from the launcher, make a best-effort cleanup by image name.
    $runtimeProcName = Get-ConfiguredStreamerProcessName
    $launchedProcName = if (-not [string]::IsNullOrWhiteSpace($Config.StreamerExePath)) {
        [System.IO.Path]::GetFileNameWithoutExtension($Config.StreamerExePath)
    } else {
        $null
    }
    if (-not [string]::IsNullOrWhiteSpace($runtimeProcName) -and $runtimeProcName -ne $launchedProcName) {
        $leftovers = @()
        try {
            $leftovers = @(Get-Process -Name $runtimeProcName -ErrorAction Stop)
        } catch {
            $leftovers = @()
        }

        foreach ($leftover in $leftovers) {
            $cleanup = Invoke-NativeCommandNoThrow -FilePath 'taskkill.exe' -Arguments @('/PID', "$($leftover.Id)", '/T', '/F')
            if ($cleanup.ExitCode -eq 0) {
                Write-Log "Cleaned up leftover runtime process '$runtimeProcName' PID $($leftover.Id)."
            }
        }
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Refresh()
        }
    } catch {
        # ignore post-kill refresh failures
    }

    if (Get-ManagedStreamerProcess) {
        Write-Log "Streamer process still appears to be running after stop request." 'WARN'
    }

    $State.StreamerPid = $null
}

function Handle-StreamerLifecycle {
    param(
        [Parameter(Mandatory = $true)]$Status
    )

    $playerCount = 0
    $streamerCount = 0

    try { $playerCount = [int]$Status.player_count } catch { $playerCount = 0 }
    try { $streamerCount = [int]$Status.streamer_count } catch { $streamerCount = 0 }

    if ($playerCount -gt 0) {
        $State.LastPlayerSeenAt = Get-Date
    }

    if ($Config.StartStreamerOnDemand -and $playerCount -gt 0 -and $streamerCount -eq 0) {
        Start-ManagedStreamer
    }

    if (-not $Config.StopStreamerOnIdle) { return }

    $proc = Get-ManagedStreamerProcess
    if (-not $proc) { return }

    if ($playerCount -gt 0) { return }

    $idleSeconds = [int]((Get-Date) - $State.LastPlayerSeenAt).TotalSeconds
    $uptimeSeconds = 0
    try {
        $uptimeSeconds = [int]((Get-Date) - $proc.StartTime).TotalSeconds
    } catch {
        $uptimeSeconds = 0
    }

    if ($idleSeconds -ge $Config.IdleTimeoutSeconds -and $uptimeSeconds -ge $Config.MinStreamerUpSeconds) {
        Write-Log "No players for $idleSeconds s (threshold $($Config.IdleTimeoutSeconds)); stopping streamer."
        Stop-ManagedStreamer -Process $proc
    }
}

function Run-Iteration {
    Ensure-TailscaleHealthy
    Start-SFUIfNeeded

    $status = Ensure-SignallingAvailable
    if (-not $status) {
        Write-Log 'Signalling REST API not reachable yet.' 'WARN'
        return
    }

    Write-Log "Signalling OK. Players=$($status.player_count) Streamers=$($status.streamer_count) UptimeMs=$($status.uptime)"
    Handle-StreamerLifecycle -Status $status
}

Write-Log "Supervisor starting. RepoRoot=$script:RepoRoot"
Write-Log "Polling every $($Config.PollSeconds)s. Set config values in pixelstreaming_supervisor.ps1 before production use."

do {
    try {
        Run-Iteration
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
    }

    if (-not $Once) {
        Start-Sleep -Seconds $Config.PollSeconds
    }
} while (-not $Once)
