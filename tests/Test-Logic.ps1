# Unit tests for the helper functions in Install-SPSE_Fix.ps1.
#
# The function definitions are extracted from the real script via the AST and dot-sourced, so these
# tests exercise the shipped code rather than a copy of it. Nothing here touches a real service.
#
# Run:  .\tests\Test-Logic.ps1        (Windows PowerShell 5.1, on the SharePoint server)
# Exits with the number of failed assertions.

$repoRoot   = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "Install-SPSE_Fix.ps1"

$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }
Write-Host "Loaded functions: $(($funcs | ForEach-Object { $_.Name }) -join ', ')`n"

# ---- stubs -------------------------------------------------------------------------------------
$script:FakeServices = @{}
$script:SetServiceCalls = @()
$script:RegistryWrites = @()

function Get-Service {
    [CmdletBinding()] param([Parameter(Position=0)]$Name)
    if (!$script:FakeServices.ContainsKey($Name)) { return $null }
    return $script:FakeServices[$Name]
}

function Get-CimInstance {
    [CmdletBinding()] param($ClassName, $Filter)
    if ($Filter -notmatch "Name='(.+)'") { return $null }
    $name = $Matches[1]
    if (!$script:FakeServices.ContainsKey($name)) { return $null }
    return $script:FakeServices[$name].Config
}

function Set-Service {
    [CmdletBinding()] param($Name, $StartupType)
    $script:SetServiceCalls += "$Name -> $StartupType"
}

function Set-ItemProperty {
    [CmdletBinding()] param($Path, $Name, $Value, $Type)
    $script:RegistryWrites += "$($Path.Split('\')[-1])\$Name = $Value"
}

function New-FakeService {
    param($Name, $Status, $StartMode, $Delayed = $false)
    $script:FakeServices[$Name] = [PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Config = [PSCustomObject]@{ StartMode = $StartMode; DelayedAutoStart = $Delayed }
    }
}

$pass = 0; $fail = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:pass++; Write-Host "  PASS  $label" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $label`n          expected: $expected`n          actual:   $actual" -ForegroundColor Red }
}

# ---- 1. Get-ServiceState -----------------------------------------------------------------------
Write-Host "Get-ServiceState"
New-FakeService -Name "SPTimerV4" -Status "Running" -StartMode "Auto"
New-FakeService -Name "OSearch16" -Status "Stopped" -StartMode "Manual"
New-FakeService -Name "W3SVC"     -Status "Running" -StartMode "Auto" -Delayed $true
New-FakeService -Name "SPCache"   -Status "Stopped" -StartMode "Disabled"

$s = Get-ServiceState @{ Name = "SPTimerV4"; Graceful = $false }
Check "running Auto service -> WasRunning true"  $true    $s.WasRunning
Check "running Auto service -> StartMode Auto"   "Auto"   $s.StartMode
Check "StartModeChanged starts false"            $false   $s.StartModeChanged

$s = Get-ServiceState @{ Name = "W3SVC"; Graceful = $false }
Check "delayed autostart detected"               $true    $s.DelayedStart

$s = Get-ServiceState @{ Name = "OSearch16"; Graceful = $false }
Check "stopped Manual service -> WasRunning false" $false  $s.WasRunning

$s = Get-ServiceState @{ Name = "NotInstalled"; Graceful = $false }
Check "service not installed -> null"            $null    $s

# ---- 2. Set-ServiceStartMode -------------------------------------------------------------------
Write-Host "`nSet-ServiceStartMode"
$script:SetServiceCalls = @(); $script:RegistryWrites = @()

Set-ServiceStartMode -Name "SPTimerV4" -StartMode "Auto"
Check "Auto maps to Automatic"      "SPTimerV4 -> Automatic" $script:SetServiceCalls[-1]
Check "delayed flag cleared when restoring non-delayed" "SPTimerV4\DelayedAutostart = 0" $script:RegistryWrites[-1]

Set-ServiceStartMode -Name "W3SVC" -StartMode "Auto" -DelayedStart $true
Check "delayed flag restored"       "W3SVC\DelayedAutostart = 1" $script:RegistryWrites[-1]

$before = $script:RegistryWrites.Count
Set-ServiceStartMode -Name "OSearch16" -StartMode "Manual"
Check "Manual passes through"       "OSearch16 -> Manual" $script:SetServiceCalls[-1]
Check "no registry write for Manual" $before $script:RegistryWrites.Count

$before = $script:SetServiceCalls.Count
Set-ServiceStartMode -Name "Weird" -StartMode "Boot"
Check "Boot drivers left alone"     $before $script:SetServiceCalls.Count

# ---- 3. graceful stop returns a clean boolean --------------------------------------------------
Write-Host "`nStop-DistributedCacheGracefully (return value purity)"
function Use-SPCacheCluster { "noise from Use-SPCacheCluster" }
function Get-SPCacheClusterHealth { "noise from Get-SPCacheClusterHealth"; [PSCustomObject]@{ Health = "OK" } }
function Import-Module { [CmdletBinding()] param([Parameter(Position=0)]$Name) "noise from Import-Module" }
function Stop-AFCacheHost { [CmdletBinding()] param([switch]$Graceful, $ComputerName, $CachePort) "noise from Stop-AFCacheHost" }
function Remove-SPDistributedCacheServiceInstance { "noise from Remove-SPDistributedCacheServiceInstance" }

$result = Stop-DistributedCacheGracefully ([PSCustomObject]@{ Name = "SPCache" })
Check "success returns exactly one value" 1     @($result).Count
Check "success returns `$true"            $true  $result

function Stop-AFCacheHost { [CmdletBinding()] param([switch]$Graceful, $ComputerName, $CachePort) throw "cache host unreachable" }
$result = Stop-DistributedCacheGracefully ([PSCustomObject]@{ Name = "SPCache" })
Check "failure returns exactly one value" 1      @($result).Count
Check "failure returns `$false"           $false  $result

# ---- 4. stop / restart ordering ----------------------------------------------------------------
Write-Host "`nStop and restart ordering"
$defsAst = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $args[0].Left.Extent.Text -eq '$ServiceDefinitions' }, $true)
$defs = & ([scriptblock]::Create($defsAst.Right.Extent.Text))

$ServiceStates = @()
foreach ($d in $defs) { $ServiceStates += [PSCustomObject]@{ Name = $d.Name } }

$reversedStates = @($ServiceStates.Clone())
[array]::Reverse($reversedStates)

Check "stop order preserved from upstream" "SPTimerV4,SPTraceV4,SPAdminV4,W3SVC,OSearch16,SPSearchHostController,SPCache" (($ServiceStates.Name) -join ',')
Check "restart order is the exact reverse"  "SPCache,SPSearchHostController,OSearch16,W3SVC,SPAdminV4,SPTraceV4,SPTimerV4" (($reversedStates.Name) -join ',')
Check "Clone did not mutate the original"   "SPTimerV4" $ServiceStates[0].Name

Write-Host "`n$pass passed, $fail failed" -ForegroundColor $(if ($fail) { "Red" } else { "Green" })
exit $fail
