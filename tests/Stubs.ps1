# Stub cmdlets used by Test-Integration.ps1. This file is prepended to a COPY of the script under
# test - see Test-Integration.ps1 for how the copy is built.
#
# SAFETY: this never touches real services. Get-Service, Set-Service, Get-CimInstance and
# Set-ItemProperty are all replaced by the functions below (a function takes precedence over a
# cmdlet of the same name), and the single Process::Start call is textually replaced with a fake.
# It is safe to run on a live SharePoint server, although a lab box is obviously preferable.
#
# Every service action is appended to $env:TESTLOG so the caller can assert on the exact sequence.

## Get-Service is stubbed below, so the assembly it would normally pull in has to be loaded explicitly:
## both the timeout thrown here and the typed catch in the script under test need the real type
Add-Type -AssemblyName System.ServiceProcess

function global:Log { param($m) Add-Content -Path $env:TESTLOG -Value $m }

$global:Fake = @{}

function global:New-FakeService {
    param($Name, $Status, $StartMode, $Delayed = $false)
    $o = [PSCustomObject]@{ Name = $Name; Status = $Status }
    $o | Add-Member -MemberType ScriptMethod -Name Stop          -Value { Log "STOP $($this.Name)";  $this.Status = "Stopped" }
    $o | Add-Member -MemberType ScriptMethod -Name Start         -Value { Log "START $($this.Name)"; $this.Status = "Running" }
    $o | Add-Member -MemberType ScriptMethod -Name Refresh       -Value { }

    ## the script always passes a TimeSpan as the second argument. $env:HANG_SERVICE names a service
    ## which never reaches the requested status, standing in for a wedged service
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($Status, $Timeout)
        if ($this.Name -eq $env:HANG_SERVICE) {
            Log "TIMEOUT $($this.Name) waiting for $Status"
            throw (New-Object System.ServiceProcess.TimeoutException "$($this.Name) did not reach $Status")
        }
    }
    $global:Fake[$Name] = [PSCustomObject]@{ Svc = $o; StartMode = $StartMode; Delayed = $Delayed }
}

# A deliberately mixed farm:
#   - four running Automatic services (W3SVC additionally flagged as delayed start)
#   - OSearch16 present but stopped and set to Manual  -> must be disabled, never started
#   - SPCache present but already Disabled             -> must be left completely alone
#   - SPSearchHostController not installed at all      -> must be skipped silently
New-FakeService -Name "SPTimerV4" -Status "Running" -StartMode "Auto"
New-FakeService -Name "SPTraceV4" -Status "Running" -StartMode "Auto"
New-FakeService -Name "SPAdminV4" -Status "Running" -StartMode "Auto"
New-FakeService -Name "W3SVC"     -Status "Running" -StartMode "Auto" -Delayed $true
New-FakeService -Name "OSearch16" -Status "Stopped" -StartMode "Manual"

## the graceful path only engages for a running cache host, so that scenario needs a different SPCache
if ($env:DCACHE_RUNNING -eq "1") {
    New-FakeService -Name "SPCache" -Status "Running" -StartMode "Auto"
} else {
    New-FakeService -Name "SPCache" -Status "Stopped" -StartMode "Disabled"
}

## $env:DCACHE_HOST decides what the farm says about this server's distributed cache role, which is
## independent of whether the SPCache service happens to be running:
##   online   - a provisioned, Online instance for this machine  -> a genuine cache host
##   offline  - an instance for this machine which is not Online -> not usable, must be left alone
##   ""       - no instance for this machine at all              -> not a cache host
## An instance belonging to another server is always returned as well, so the filter has something to
## reject rather than an empty farm to pass by default.
function global:New-FakeServiceInstance {
    param($ServerName, $Status, $InstanceName = "SPDistributedCacheService Name=SPCache")

    ## the real Service property is an SPDistributedCacheService whose ToString carries the name, and
    ## the script compares it as a string - so the stub has to stringify the same way
    $service = [PSCustomObject]@{}
    $service | Add-Member -MemberType ScriptMethod -Name ToString -Value ([scriptblock]::Create("'$InstanceName'")) -Force

    return [PSCustomObject]@{
        Service = $service
        Server  = [PSCustomObject]@{ Name = $ServerName }
        Status  = $Status
    }
}

function global:Get-SPServiceInstance {
    [CmdletBinding()] param()

    Log "DCACHE GETINSTANCE"

    if ($env:DCACHE_HOST -eq "throw") { throw "the farm is not reachable" }

    ## an instance on a different server, and a search instance on this one: both have to be filtered out
    $instances = @(
        New-FakeServiceInstance -ServerName "SOMEOTHERSERVER" -Status "Online"
        New-FakeServiceInstance -ServerName $env:COMPUTERNAME -Status "Online" -InstanceName "SPSearchServiceInstance"
    )

    if ($env:DCACHE_HOST -eq "online")  { $instances += New-FakeServiceInstance -ServerName $env:COMPUTERNAME -Status "Online" }
    if ($env:DCACHE_HOST -eq "offline") { $instances += New-FakeServiceInstance -ServerName $env:COMPUTERNAME -Status "Disabled" }

    return $instances
}

## these run on a real SharePoint server, where the genuine cache cmdlets resolve and would act on the
## live farm. Shadowing them is what keeps the graceful path safe to exercise here.
function global:Use-SPCacheCluster { Log "DCACHE USECLUSTER" }
function global:Get-SPCacheClusterHealth { Log "DCACHE HEALTH" }
function global:Remove-SPDistributedCacheServiceInstance { Log "DCACHE REMOVE" }
function global:Add-SPDistributedCacheServiceInstance { Log "DCACHE ADD" }

function global:Stop-SPDistributedCacheServiceInstance {
    [CmdletBinding()] param([switch]$Graceful, [switch]$Force, $Timeout, $Identity)
    if ($env:SCENARIO -eq "dcachefail") { throw "the cache cluster is unreachable" }
    Log "DCACHE STOP graceful=$Graceful timeout=$Timeout"
}

function global:Get-Service {
    [CmdletBinding()] param([Parameter(Position=0)]$Name)
    if (!$global:Fake.ContainsKey($Name)) { return $null }
    return $global:Fake[$Name].Svc
}

function global:Get-CimInstance {
    [CmdletBinding()] param($ClassName, $Filter)
    if ($Filter -notmatch "Name='(.+)'") { return $null }
    $n = $Matches[1]
    if (!$global:Fake.ContainsKey($n)) { return $null }
    return [PSCustomObject]@{ StartMode = $global:Fake[$n].StartMode; DelayedAutoStart = $global:Fake[$n].Delayed }
}

function global:Set-Service {
    [CmdletBinding()] param($Name, $StartupType)
    Log "SETMODE $Name -> $StartupType"
}

function global:Set-ItemProperty {
    [CmdletBinding()] param($Path, $Name, $Value, $Type)
    Log "REG $($Path.Split('\')[-1])\$Name = $Value"
}

## logged so that a run can assert whether the confirmation prompt was reached at all
function global:Read-Host { param([Parameter(Position=0)]$Prompt) Log "PROMPT"; return "" }

$global:SleepCount = 0
function global:Start-Sleep {
    [CmdletBinding()] param([Parameter(Position=0)]$Seconds)
    $global:SleepCount++
    if ($env:SCENARIO -eq "interrupted" -and $global:SleepCount -ge 2) {
        throw "simulated interruption while the installer was still running"
    }
}

function global:New-FakeProcess {
    if ($env:SCENARIO -eq "launchfail") { throw "The system cannot execute the specified program." }

    Log "LAUNCH installer"
    $p = [PSCustomObject]@{ ExitCode = [int]$env:INSTALLER_EXIT }

    if ($env:SCENARIO -eq "interrupted") {
        # the installer never finishes, mimicking an abort part way through
        $p | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $false }
    } else {
        $p | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $true }
    }

    return $p
}
