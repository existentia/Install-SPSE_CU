# Stub cmdlets used by Test-Integration.ps1. This file is prepended to a COPY of the script under
# test - see Test-Integration.ps1 for how the copy is built.
#
# SAFETY: this never touches real services. Get-Service, Set-Service, Get-CimInstance and
# Set-ItemProperty are all replaced by the functions below (a function takes precedence over a
# cmdlet of the same name), and the single Process::Start call is textually replaced with a fake.
# It is safe to run on a live SharePoint server, although a lab box is obviously preferable.
#
# Every service action is appended to $env:TESTLOG so the caller can assert on the exact sequence.

function global:Log { param($m) Add-Content -Path $env:TESTLOG -Value $m }

$global:Fake = @{}

function global:New-FakeService {
    param($Name, $Status, $StartMode, $Delayed = $false)
    $o = [PSCustomObject]@{ Name = $Name; Status = $Status }
    $o | Add-Member -MemberType ScriptMethod -Name Stop          -Value { Log "STOP $($this.Name)";  $this.Status = "Stopped" }
    $o | Add-Member -MemberType ScriptMethod -Name Start         -Value { Log "START $($this.Name)"; $this.Status = "Running" }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($s) }
    $o | Add-Member -MemberType ScriptMethod -Name Refresh       -Value { }
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
New-FakeService -Name "SPCache"   -Status "Stopped" -StartMode "Disabled"

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

function global:Read-Host { param([Parameter(Position=0)]$Prompt) return "" }

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
