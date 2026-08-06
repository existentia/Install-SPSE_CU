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

## the farm's answer about this server's distributed cache role. $script:CacheInstanceStatus of $null
## means no instance is registered for this machine at all
$script:CacheInstanceStatus = "Online"
function Get-SPServiceInstance {
    [CmdletBinding()] param()

    if ($script:CacheInstanceStatus -eq "throw") { throw "the farm is not reachable" }

    ## the real Service property stringifies to the instance name, and an instance belonging to another
    ## server is always present so that the filter has something to reject
    $mk = {
        param($ServerName, $Status, $Name = "SPDistributedCacheService Name=SPCache")
        $svc = [PSCustomObject]@{}
        $svc | Add-Member -MemberType ScriptMethod -Name ToString -Value ([scriptblock]::Create("'$Name'")) -Force
        [PSCustomObject]@{ Service = $svc; Server = [PSCustomObject]@{ Name = $ServerName }; Status = $Status }
    }

    $instances = @((& $mk "SOMEOTHERSERVER" "Online"))

    if ($null -ne $script:CacheInstanceStatus -and $script:CacheInstanceStatus -ne "throw") {
        $instances += (& $mk $env:COMPUTERNAME $script:CacheInstanceStatus)
    }

    return $instances
}
function Stop-SPDistributedCacheServiceInstance { [CmdletBinding()] param([switch]$Graceful, [switch]$Force, $Timeout, $Identity) "noise from Stop-SPDistributedCacheServiceInstance" }
function Remove-SPDistributedCacheServiceInstance { "noise from Remove-SPDistributedCacheServiceInstance" }
function Add-SPDistributedCacheServiceInstance { "noise from Add-SPDistributedCacheServiceInstance" }

$result = Stop-DistributedCacheGracefully ([PSCustomObject]@{ Name = "SPCache" })
Check "success returns exactly one value" 1     @($result).Count
Check "success returns `$true"            $true  $result

function Stop-SPDistributedCacheServiceInstance { [CmdletBinding()] param([switch]$Graceful, [switch]$Force, $Timeout, $Identity) throw "cache host unreachable" }
$result = Stop-DistributedCacheGracefully ([PSCustomObject]@{ Name = "SPCache" })
Check "failure returns exactly one value" 1      @($result).Count
Check "failure returns `$false"           $false  $result

# ---- 3b. the graceful path checks its prerequisites --------------------------------------------
Write-Host "`nTest-DistributedCacheSupport"

## an explicit list is passed for the negative case because this test also runs on a real SharePoint
## server, where Get-Command would find the genuine cmdlets no matter what the stubs do
Check "all required cmdlets present -> true"  $true  (Test-DistributedCacheSupport)
Check "a missing cmdlet -> false"             $false (Test-DistributedCacheSupport -RequiredCmdlets @("Get-Command", "Definitely-NotARealCmdlet"))

## the role check needs it, and it is the cmdlet which decides whether anything else runs at all
$requiredAst = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq "Test-DistributedCacheSupport" }, $true)
Check "Get-SPServiceInstance is a prerequisite" $true ($requiredAst.Extent.Text -match "Get-SPServiceInstance")

# ---- 3c. the role check: the cache cmdlets only ever run on a real cache host -------------------
Write-Host "`nTest-IsDistributedCacheHost"

## the SPCache service is installed on every server in the farm and can be found running on a server
## whose instance is not provisioned, so only the farm's own answer counts
$script:CacheInstanceStatus = "Online"
Check "a provisioned Online instance -> true"    $true  (Test-IsDistributedCacheHost)

$script:CacheInstanceStatus = $null
Check "no instance for this server -> false"     $false (Test-IsDistributedCacheHost)

$script:CacheInstanceStatus = "Disabled"
Check "an instance which is not Online -> false" $false (Test-IsDistributedCacheHost)

$script:CacheInstanceStatus = "Provisioning"
Check "an instance still provisioning -> false"  $false (Test-IsDistributedCacheHost)

## an unreachable farm is not evidence that this server is a cache host. Failing closed costs a plain
## service stop; failing open runs Remove-SPDistributedCacheServiceInstance somewhere it must not
$script:CacheInstanceStatus = "throw"
Check "an unreachable farm -> false"             $false (Test-IsDistributedCacheHost)

$script:CacheInstanceStatus = "Online"
Check "an instance on another server only -> false" $false (Test-IsDistributedCacheHost -ComputerName "NOTTHISSERVER")
Check "a different service instance -> false"    $false (Test-IsDistributedCacheHost -InstanceName "SPSearchServiceInstance")

Check "the answer is a single clean boolean"     1      @(Test-IsDistributedCacheHost).Count

## and the graceful path must consult it - not the service status
$gracefulAst = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq "Stop-DistributedCacheGracefully" }, $true)
Check "the graceful path checks the role"        $true ($gracefulAst.Extent.Text -match "Test-IsDistributedCacheHost")

$removeCalls = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
    $args[0].GetCommandName() -eq "Remove-SPDistributedCacheServiceInstance" }, $true))
Check "Remove- is called from exactly one place" 1 $removeCalls.Count
Check "and that place is the graceful path"      $true ($gracefulAst.Extent.Text -match "Remove-SPDistributedCacheServiceInstance")

# ---- 3d. the instance is only provisioned again if this run unprovisioned it --------------------
Write-Host "`nRestore-ServiceState and the cache instance"

$script:AddCalls = 0
function Add-SPDistributedCacheServiceInstance { $script:AddCalls++ }

function New-CacheState {
    param([bool]$Unprovisioned)

    $svc = [PSCustomObject]@{ Name = "SPCache"; Status = "Stopped"; Started = $false }
    $svc | Add-Member -MemberType ScriptMethod -Name Refresh       -Value { }
    $svc | Add-Member -MemberType ScriptMethod -Name Start         -Value { $this.Started = $true; $this.Status = "Running" }
    $svc | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) }

    return [PSCustomObject]@{
        Name = "SPCache"; Graceful = $true; Service = $svc; WasRunning = $true
        StartMode = "Auto"; DelayedStart = $false; StartModeChanged = $false
        Unprovisioned = $Unprovisioned
    }
}

## the caching service is stopped last, so a run abandoned in the stop loop reaches the restore with
## the instance still provisioned. Provisioning it again there would be acting on a cache host this
## run never took down
$state = New-CacheState -Unprovisioned $false
Restore-ServiceState -ServiceStates @($state) -StartServices $true -TimeoutSeconds 5 | Out-Null
Check "an instance we did not remove is not added" 0     $script:AddCalls
Check "it is started as a plain service instead"   $true  $state.Service.Started

$script:AddCalls = 0
$state = New-CacheState -Unprovisioned $true
Restore-ServiceState -ServiceStates @($state) -StartServices $true -TimeoutSeconds 5 | Out-Null
Check "an instance we did remove is provisioned"   1      $script:AddCalls
Check "and it is not also started by hand"         $false  $state.Service.Started
Check "the flag is cleared so a second call is safe" $false $state.Unprovisioned

Restore-ServiceState -ServiceStates @($state) -StartServices $true -TimeoutSeconds 5 | Out-Null
Check "a second restore does not provision twice"  1      $script:AddCalls

## mid-install the instance must not come back, because the services are not being started at all
$script:AddCalls = 0
$state = New-CacheState -Unprovisioned $true
Restore-ServiceState -ServiceStates @($state) -StartServices $false -TimeoutSeconds 5 | Out-Null
Check "not provisioned while the installer runs"   0      $script:AddCalls
Check "and the debt is still recorded"             $true   $state.Unprovisioned

## the cache is driven entirely through the SharePoint cmdlets, which need no module import
$invoked = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() })
Check "only SharePoint cache cmdlets are used" 0      @($invoked | Where-Object { $_ -like "*-AF*" }).Count
Check "the SharePoint graceful stop is used"   $true  ($invoked -contains "Stop-SPDistributedCacheServiceInstance")
Check "no module import is needed"             $false ($invoked -contains "Import-Module")

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

# ---- 5. bounded waits ---------------------------------------------------------------------------
Write-Host "`nWait-ForServiceStatus and Stop-ServiceIfRunning"

## the real type has to be loaded for the typed catch inside Wait-ForServiceStatus to resolve. The
## script gets that for free from Get-Service, which is stubbed out in here
Add-Type -AssemblyName System.ServiceProcess

function New-WaitStub {
    param([bool]$TimesOut)

    $o = [PSCustomObject]@{ Name = "Fake"; Status = "Running"; WaitArgs = $null; Stopped = $false; TimesOut = $TimesOut }
    $o | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($Status, $Timeout)
        $this.WaitArgs = "$Status/$($Timeout.TotalSeconds)"
        if ($this.TimesOut) { throw (New-Object System.ServiceProcess.TimeoutException "did not reach $Status") }
    }
    return $o
}

$svc = New-WaitStub -TimesOut $false
Check "reaching the status returns true"        $true        (Wait-ForServiceStatus -Service $svc -Status "Stopped" -TimeoutSeconds 30)
Check "the timeout is passed as a TimeSpan"     "Stopped/30" $svc.WaitArgs

$svc = New-WaitStub -TimesOut $true
Check "a timeout returns false, not an error"   $false       (Wait-ForServiceStatus -Service $svc -Status "Stopped" -TimeoutSeconds 5)

## only a timeout may be turned into a false - a permissions failure or anything else has to surface
$svc = [PSCustomObject]@{ Name = "Fake" }
$svc | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) throw "access is denied" }
$threw = $false
try { Wait-ForServiceStatus -Service $svc -Status "Stopped" -TimeoutSeconds 5 | Out-Null } catch { $threw = $true }
Check "a non-timeout error is not swallowed"    $true        $threw

## a service which will not stop must be reported, never treated as stopped - the installer would then
## run while the file locks are still held, which is the problem the script exists to solve
$state = [PSCustomObject]@{ Name = "SPTimerV4"; WasRunning = $true; Service = (New-WaitStub -TimesOut $true) }
Check "a service that will not stop -> false"   $false (Stop-ServiceIfRunning -State $state -TimeoutSeconds 5)

$state = [PSCustomObject]@{ Name = "SPTimerV4"; WasRunning = $true; Service = (New-WaitStub -TimesOut $false) }
Check "a service that stops -> true"            $true  (Stop-ServiceIfRunning -State $state -TimeoutSeconds 5)
Check "and it really was stopped"               $true  $state.Service.Stopped

$state = [PSCustomObject]@{ Name = "OSearch16"; WasRunning = $false; Service = (New-WaitStub -TimesOut $true) }
Check "a service that was not running -> true"  $true  (Stop-ServiceIfRunning -State $state -TimeoutSeconds 5)
Check "and it was never touched"                $false $state.Service.Stopped

## guards against an unbounded wait being reintroduced: those can only be escaped by killing the
## process, which is the one case the finally block cannot recover from
$waitCalls = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $args[0].Member.Value -eq "WaitForStatus" }, $true))
Check "there is a WaitForStatus call to check"  $true ($waitCalls.Count -gt 0)
Check "every WaitForStatus call is bounded"     0     @($waitCalls | Where-Object { $_.Arguments.Count -lt 2 }).Count

# ---- 6. the parameter surface -------------------------------------------------------------------
Write-Host "`nParameters"

$declared = @{}
foreach ($p in $ast.ParamBlock.Parameters) { $declared[$p.Name.VariablePath.UserPath] = $p }

## a switch, so that the graceful shutdown reads -ShouldGracefulStopDCache rather than the
## unidiomatic -ShouldGracefulStopDCache $true that 1.6 required
Check "ShouldGracefulStopDCache is a switch" "SwitchParameter" $declared["ShouldGracefulStopDCache"].StaticType.Name
Check "there is a Force switch"              "SwitchParameter" $declared["Force"].StaticType.Name
Check "the timeout is an int"                "Int32"           $declared["ServiceTimeoutSeconds"].StaticType.Name

## the graceful shutdown is on by default, and the opt out is a switch of its own because
## -ShouldGracefulStopDCache:$false does not survive powershell.exe -File
Check "the graceful shutdown defaults to on" '$true'           $declared["ShouldGracefulStopDCache"].DefaultValue.Extent.Text
Check "there is a -File safe opt out"        "SwitchParameter" $declared["NoGracefulStopDCache"].StaticType.Name
Check "the opt out defaults to off"          $null             $declared["NoGracefulStopDCache"].DefaultValue

## validating at bind time is what makes an unattended run fail immediately rather than start and stop
$culocAttributes = @($declared["CULocation"].Attributes | ForEach-Object { $_.TypeName.Name })
Check "CULocation is validated at bind time" $true ($culocAttributes -contains "ValidateScript")

## the prompt has to be reachable only when -Force was not given, otherwise an unattended run blocks
$readHostCalls = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
    $args[0].GetCommandName() -eq "Read-Host" }, $true))
Check "there is exactly one Read-Host"       1     $readHostCalls.Count

$guarded = $false
$parent = $readHostCalls[0].Parent
while ($null -ne $parent)
{
    if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and $parent.Extent.Text -match '\$Force')
    {
        $guarded = $true
        break
    }
    $parent = $parent.Parent
}
Check "the prompt is guarded by -Force"      $true  $guarded

Write-Host "`n$pass passed, $fail failed" -ForegroundColor $(if ($fail) { "Red" } else { "Green" })
exit $fail
