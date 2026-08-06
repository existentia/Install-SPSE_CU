<#
 This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment.
 THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.
 We grant you a nonexclusive, royalty-free right to use and modify the sample code and to reproduce and distribute the object
 code form of the Sample Code, provided that you agree:
    (i)   to not use our name, logo, or trademarks to market your software product in which the sample code is embedded;
    (ii)  to include a valid copyright notice on your software product in which the sample code is embedded; and
    (iii) to indemnify, hold harmless, and defend us and our suppliers from and against any claims or lawsuits, including
          attorneys' fees, that arise or result from the use or distribution of the sample code.
 Please note: None of the conditions outlined in the disclaimer above will supercede the terms and conditions contained within
              the Premier Customer Services Description.


  SUMMARY:

   This script identifies and stops/restarts Services to reduce the patch install time for SharePoint Server Subscription Edition Cumlative Update.
   As input parameter it takes the path to the SharePoint patch to be installed and
   whether a graceful shutdown of the distributed cache on the current server should be performed if the current machine hosts the distributed cache service

   Reference: https://blog.stefan-gossner.com/2024/03/08/solving-the-extended-install-time-for-spse-cus/

   Version History:
    1.0 - initial version
    1.1 - add error detection to detect installation failures and some common errors
    1.2 - add handling of exit code 17022 which indicates that the installation succeeded but a reboot is required to complete the installation
    1.3 - quick fix of elseif statement
    1.4 - allow server relative paths
    1.5 - fix incorrect if condition for restarting OSearch16 service at the end of the script
    1.6 - add line break after fix installation has been initiated message for better readability of the output
    1.7 - collected fixes:
          - report durations of one hour or more correctly
          - return the installer exit code to the caller so that failures can be detected by automation
          - temporarily set the startup type of the affected services to Disabled while the patch is applied so
            that neither the installer nor a Service Control Manager recovery action can restart them
          - restore the startup type each service originally had and only restart the services which were
            actually running before the script was started
          - skip services which are not installed on the current server rather than reporting an error
          - restore the startup types from a finally block so that a failed, cancelled or aborted
            installation cannot leave the services stopped and disabled. Note that a forced termination
            of the PowerShell process itself (Task Manager, taskkill, closing the console window) cannot
            be intercepted - see "Recovering from a forced termination" below
          - drop the hardcoded module import and the hardcoded cache port from the graceful distributed
            cache shutdown. Stop-SPDistributedCacheServiceInstance -Graceful performs the shutdown and
            the SharePointServer module which supplies it loads on demand, so the graceful path does not
            have to be run from the SharePoint Management Shell
          - check that the cmdlets the graceful path relies on are present before anything is stopped,
            and run the whole graceful path inside its own try, so that a missing prerequisite falls
            back to a plain service stop rather than aborting the installation
          - bound every wait. WaitForStatus was called without a timeout, so a service which never
            stopped or never started left the script hanging forever - and the only way out of a hang
            is to kill the process, which is precisely the case the finally block cannot recover from.
            All waits now use the TimeSpan overload, controlled by -ServiceTimeoutSeconds, and the
            graceful cache shutdown passes the same value to -Timeout
          - abandon the run if a service cannot be stopped, rather than patching around it. Installing
            while a service still holds its file locks is the problem this script exists to avoid
          - restore each service inside its own try, so that one service failing to come back cannot
            abandon the restore of the others
          - add -Force to skip the confirmation prompt, so that the script can be driven across a farm
            without an operator at the console
          - validate -CULocation as it is bound rather than after the script has started, and resolve a
            relative path against the current file system location so that a current location on
            another provider, such as HKLM:\, cannot silently produce a nonsense path
          - confirm through Get-SPServiceInstance that this server really is a distributed cache host
            before running any distributed cache cmdlet against it. The SPCache service is installed on
            every server in the farm and can be found running on a server whose service instance is not
            provisioned, so the service status was never sufficient evidence of the role
          - only provision the cache service instance again if this run was the one which unprovisioned
            it. The caching service is stopped last, so any run abandoned in the stop loop previously
            reached Add-SPDistributedCacheServiceInstance with the instance still provisioned
          - tell the operator that the caching service is the one service not to start by hand if the
            run is interrupted after its instance has been unprovisioned
          - BREAKING CHANGE: -ShouldGracefulStopDCache is now a switch. Call it as
            -ShouldGracefulStopDCache where version 1.6 and earlier needed -ShouldGracefulStopDCache $true
          - BREAKING CHANGE: -ShouldGracefulStopDCache now defaults to on, because it can no longer
            engage on a server which does not host the distributed cache. Opt out with the new
            -NoGracefulStopDCache, which stops the caching service outright and loses the data held in
            the cache. -ShouldGracefulStopDCache:$false does the same but does not survive
            powershell.exe -File, where every argument arrives as a literal string

   Exit Codes:
    The script returns the exit code of the patch installer so that the outcome can be evaluated by
    automation. 0 indicates success. 17022 indicates that the installation succeeded but that a reboot
    is required. Any other value indicates a failure - see the error table below for the known codes.
    An exit code of 1 indicates that the patch path was not valid, or that the script was interrupted
    before the installation completed.

   Recovering from a forced termination:
    If the PowerShell process is killed outright between the services being disabled and the
    installation finishing, the affected services are left stopped and with a startup type of Disabled.
    The script reports which services it disabled, and with which startup type, before it makes any
    change - so the original values can be read back from the console output. To recover, wait for the
    installation to finish, put the startup types back and start the services which this server's role
    requires. Check the values against another server in the farm first: not every service is set to
    Automatic on every role, so a blanket reset to Automatic is not necessarily correct.

#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param (
    ## validated as it is bound, so an unattended run fails immediately with a non zero exit code
    ## instead of starting and then stopping. The resolution below is repeated in the body because a
    ## validation attribute cannot assign the resolved value back to the parameter
    [Parameter(Mandatory=$true)]
    [ValidateScript({
        $resolved = $_

        if (![System.IO.Path]::IsPathRooted($resolved))
        {
            $resolved = Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $resolved
        }

        if ([System.IO.Path]::GetExtension($resolved) -ne ".exe")
        {
            throw "The SharePoint Server Subscription Edition update has to be an .exe, for example C:\temp\uber-subscription-kb5002560-fullfile-x64-glb.exe"
        }

        if (!(Test-Path -LiteralPath $resolved -PathType Leaf))
        {
            throw "The SharePoint Server Subscription Edition update was not found at $resolved"
        }

        $true
    })]
    [string]$CULocation,

    ## on by default: the graceful shutdown is the procedure Microsoft documents for taking a cache host
    ## down, and it now engages only where the server really is a distributed cache host - see
    ## Test-IsDistributedCacheHost. Everywhere else it costs nothing because it never runs.
    ## Version 1.6 and earlier took a [bool], defaulted to off, and had to be called with
    ## -ShouldGracefulStopDCache $true
    [Parameter(Mandatory=$false)]
    [switch]$ShouldGracefulStopDCache = $true,

    ## the way to turn the graceful shutdown off. -ShouldGracefulStopDCache:$false also works, but only
    ## when the script is dot sourced or called through powershell.exe -Command. Under
    ## powershell.exe -File - which is how an unattended run across a farm is usually driven - every
    ## argument arrives as a literal string, so :$false is the string "$false" and the bind fails
    ## outright. This switch works under both. If both are given, this one wins
    [Parameter(Mandatory=$false)]
    [switch]$NoGracefulStopDCache,

    ## how long to wait for a single service to stop or start, and for the graceful shutdown of the
    ## distributed cache. Applies per service, not to the run as a whole
    [Parameter(Mandatory=$false)]
    [int]$ServiceTimeoutSeconds = 300,

    ## skip the confirmation prompt so that the script can be driven across a farm without an operator
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

## the explicit opt out wins over the default, and over -ShouldGracefulStopDCache having been passed
## as well. Everything downstream reads $ShouldGracefulStopDCache alone
if ($NoGracefulStopDCache)
{
    $ShouldGracefulStopDCache = $false
}

## the base for a relative path is taken from Get-Location -PSProvider FileSystem rather than $PWD, so
## that running with a current location on another provider - HKLM:\ for instance - cannot silently
## produce a nonsense path
if (![System.IO.Path]::IsPathRooted($CULocation))
{
    $CULocation = Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $CULocation
}

$CULocation = [System.IO.Path]::GetFullPath($CULocation)

# List of common patch installation errors
$ErrorMap = @{

    -1    = 'The installation of the patch failed.'
    17300 = 'An error has occurred during the installation of this fix.'
    17301 = 'The detection failed, this can be due to a corrupted installation database.'
    17302 = 'The installation of the patch failed.'
    17303 = 'An error has occurred while extracting the files from this package.'

    17021 = 'An error has occurred during the installation of this fix.'
    17022 = 'A reboot is required to complete the installation of the fix.'
    17023 = 'The installation of this package was cancelled.'
    17025 = 'The update is already installed on this system.'
    17028 = 'There are no products affected by this package installed on this system.'
    17030 = 'The detection failed, this can be due to a corrupted installation database.'
    17032 = 'Insufficient disk space to install the fix.'
}

# The services are stopped in the order listed below and restarted in the reverse order.
# Graceful marks the service which hosts the distributed cache and which can optionally be shut
# down through the AppFabric cmdlets instead of simply being stopped.
$ServiceDefinitions = @(
    @{ Name = "SPTimerV4"              ; Graceful = $false }
    @{ Name = "SPTraceV4"              ; Graceful = $false }
    @{ Name = "SPAdminV4"              ; Graceful = $false }
    @{ Name = "W3SVC"                  ; Graceful = $false }
    @{ Name = "OSearch16"              ; Graceful = $false }
    @{ Name = "SPSearchHostController" ; Graceful = $false }
    @{ Name = "SPCache"                ; Graceful = $true  }
)

function Get-ExitMessage {
    param($Code)

    if ($ErrorMap.ContainsKey($Code)) {
        return $ErrorMap[$Code] + " (ExitCode: $Code)"
    }

    return "An Error has occurred during the installation. (ExitCode: $Code)"
}

function Format-Duration {
    param([TimeSpan]$Duration)

    ## the Minutes property only holds the minutes component of the duration and wraps at 60
    ## use the total value so that installations taking an hour or more are reported correctly

    if ($Duration.TotalHours -ge 1) {
        return "{0} Hours, {1} Minutes, {2} Seconds" -f [Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
    }

    return "{0} Minutes, {1} Seconds" -f [Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
}

function Get-ServiceState {
    param([hashtable]$Definition)

    ## a server only runs the services which match its role, so a service which is not installed
    ## on the current machine is skipped rather than being reported as an error
    $service = Get-Service $Definition.Name -ErrorAction SilentlyContinue

    if ($null -eq $service) {
        return $null
    }

    ## Win32_Service is used in preference to the StartType property of the service object because
    ## it also reports whether an automatic service is configured for delayed start
    $config = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Definition.Name)'" -ErrorAction SilentlyContinue

    $startMode = $null
    $delayedStart = $false

    if ($null -ne $config) {
        $startMode = $config.StartMode
        $delayedStart = [bool]$config.DelayedAutoStart
    }

    return [PSCustomObject]@{
        Name             = $Definition.Name
        Graceful         = $Definition.Graceful
        Service          = $service
        WasRunning       = ($service.Status -eq "Running")
        StartMode        = $startMode
        DelayedStart     = $delayedStart
        StartModeChanged = $false

        ## set only once this run has actually unprovisioned the distributed cache service instance on
        ## this server, and cleared once it has been provisioned again. It records what was done rather
        ## than what was asked for, which is what makes it safe for Restore-ServiceState to key on:
        ## Add-SPDistributedCacheServiceInstance must never run against an instance this run did not
        ## remove
        Unprovisioned    = $false
    }
}

function Set-ServiceStartMode {
    param(
        [string]$Name,
        [string]$StartMode,
        [bool]$DelayedStart = $false
    )

    ## Win32_Service reports the mode of an automatic service as "Auto" while Set-Service expects "Automatic"
    $startupType = switch ($StartMode) {
        "Auto"     { "Automatic" }
        "Manual"   { "Manual" }
        "Disabled" { "Disabled" }
        default    { $null }
    }

    if ($null -eq $startupType) {
        ## boot and system start drivers are never touched by this script
        return
    }

    Set-Service -Name $Name -StartupType $startupType

    ## Set-Service cannot express "Automatic (Delayed Start)" so that flag has to be restored directly
    if ($startupType -eq "Automatic") {
        $delayedValue = 0
        if ($DelayedStart) { $delayedValue = 1 }
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name "DelayedAutostart" -Value $delayedValue -Type DWord -ErrorAction SilentlyContinue
    }
}

function Wait-ForServiceStatus {
    ## $Service is deliberately untyped so that the off-farm tests can pass a stub in place of a
    ## ServiceController
    param(
        $Service,
        [string]$Status,
        [int]$TimeoutSeconds
    )

    ## the parameterless WaitForStatus overload waits forever. A service which never reaches the
    ## requested status would hang the script with no way out other than killing the process - and a
    ## forced kill is the one failure mode the finally block cannot recover from, leaving the services
    ## stopped and disabled. The TimeSpan overload bounds the wait instead.
    try
    {
        $Service.WaitForStatus($Status, [TimeSpan]::FromSeconds($TimeoutSeconds))
        return $true
    }
    catch
    {
        ## a timeout is an expected outcome and is reported by returning false. PowerShell wraps an
        ## exception thrown out of a method call in a MethodInvocationException, and a typed catch only
        ## unwraps one level, so the whole chain is walked rather than relying on that. Anything which
        ## is not a timeout is a genuine failure and is left to propagate
        $exception = $_.Exception

        while ($null -ne $exception)
        {
            if ($exception -is [System.ServiceProcess.TimeoutException])
            {
                return $false
            }

            $exception = $exception.InnerException
        }

        throw
    }
}

function Stop-ServiceIfRunning {
    param(
        [PSCustomObject]$State,
        [int]$TimeoutSeconds
    )

    if (!$State.WasRunning) {
        return $true
    }

    Write-Host "Stopping $($State.Name) service..."
    $State.Service.Stop()

    if (Wait-ForServiceStatus -Service $State.Service -Status "Stopped" -TimeoutSeconds $TimeoutSeconds)
    {
        return $true
    }

    Write-Host -ForegroundColor Red "$($State.Name) did not stop within $TimeoutSeconds seconds."
    return $false
}

function Test-DistributedCacheSupport {

    ## every cmdlet used by the graceful path comes from the SharePointServer module. On Subscription
    ## Edition that module is on PSModulePath and loads on demand, so nothing has to be imported and no
    ## Add-PSSnapin is needed - the graceful path is not restricted to the SharePoint Management Shell.
    ##
    ## Add-SPDistributedCacheServiceInstance is checked even though it is only used after the patch: the
    ## service instance must not be unprovisioned unless it can also be provisioned again afterwards.
    ##
    ## the list is a parameter purely so that the off-farm tests can exercise the missing-cmdlet path on
    ## a machine where the real cmdlets are installed - the script itself always uses the default
    param(
        [string[]]$RequiredCmdlets = @(
            "Get-SPServiceInstance"
            "Use-SPCacheCluster"
            "Get-SPCacheClusterHealth"
            "Stop-SPDistributedCacheServiceInstance"
            "Remove-SPDistributedCacheServiceInstance"
            "Add-SPDistributedCacheServiceInstance"
        )
    )

    foreach ($cmdlet in $RequiredCmdlets)
    {
        if (!(Get-Command $cmdlet -ErrorAction SilentlyContinue))
        {
            Write-Host -ForegroundColor Yellow "$cmdlet is not available on this server."
            return $false
        }
    }

    return $true
}

function Test-IsDistributedCacheHost {

    ## the SPCache Windows service being installed and running is NOT the same thing as this server
    ## being a distributed cache host. SharePoint installs the service on every server in the farm, and
    ## it can be found running on a server whose service instance is not provisioned at all - the state
    ## which produces the familiar "cacheHostInfo is null" error. Remove-SPDistributedCacheServiceInstance
    ## and Add-SPDistributedCacheServiceInstance must not be run there, so the service status is not
    ## trusted as a proxy for the role: the authoritative answer is the service instance registered for
    ## this machine, queried the way Microsoft documents it.
    ##
    ## https://learn.microsoft.com/sharepoint/administration/manage-the-distributed-cache-service
    ##
    ## the instance name and computer name are parameters purely so that the off-farm tests can drive
    ## both answers - the script itself always uses the defaults
    param(
        [string]$InstanceName = "SPDistributedCacheService Name=SPCache",
        [string]$ComputerName = $env:COMPUTERNAME
    )

    if (!(Get-Command "Get-SPServiceInstance" -ErrorAction SilentlyContinue))
    {
        Write-Host -ForegroundColor Yellow "Get-SPServiceInstance is not available, so it cannot be confirmed that this server hosts the distributed cache."
        return $false
    }

    ## a farm which cannot be reached is not evidence that this server is a cache host, so any failure
    ## here answers no. The cost of a false no is a plain service stop; the cost of a false yes is
    ## running the cache cmdlets against a server that does not host the cache
    try
    {
        $instance = @(Get-SPServiceInstance -ErrorAction Stop |
            Where-Object { "$($_.Service)" -eq $InstanceName -and "$($_.Server.Name)" -eq $ComputerName })
    }
    catch
    {
        $_ | Out-Host
        Write-Host -ForegroundColor Yellow "The distributed cache service instances could not be read, so it cannot be confirmed that this server hosts the distributed cache."
        return $false
    }

    if ($instance.Count -eq 0)
    {
        Write-Host "$ComputerName does not host the distributed cache, so the distributed cache cmdlets will not be run against it."
        return $false
    }

    ## an instance which is registered but not Online is not serving cache, and unprovisioning it is
    ## both unnecessary and liable to fail. Status is compared as a string so that the SPObjectStatus
    ## enum does not have to be loaded
    $status = "$($instance[0].Status)"

    if ($status -ne "Online")
    {
        Write-Host -ForegroundColor Yellow "The distributed cache service instance on $ComputerName is $status rather than Online, so the distributed cache cmdlets will not be run against it."
        return $false
    }

    return $true
}

function Stop-DistributedCacheGracefully {
    param(
        [PSCustomObject]$State,
        [int]$TimeoutSeconds = 300
    )

    ## the output of the cmdlets below is sent straight to the host so that it does not end up
    ## in the return value of this function

    ## the whole graceful path runs inside this try, including the prerequisite check. A missing cmdlet
    ## or an unreachable cache cluster therefore falls back to a plain stop of the service rather than
    ## throwing out of this function and aborting the installation
    try
    {
        if (!(Test-DistributedCacheSupport))
        {
            Write-Host -ForegroundColor Yellow "Will fallback to non graceful stop of the caching service."
            return $false
        }

        ## a server which does not host the distributed cache is not a failure and is not reported as
        ## one - the caching service is simply stopped and restarted like every other service in the list
        if (!(Test-IsDistributedCacheHost))
        {
            Write-Host "The caching service will be stopped and restarted like any other service."
            return $false
        }

        Use-SPCacheCluster | Out-Host
        Get-SPCacheClusterHealth | Out-Host

        Write-Host "Graceful stopping Cache Host..."

        ## -Timeout bounds the handover of the cached data in the same way the WaitForStatus calls are
        ## bounded. Without it a cluster which cannot move its data to another host blocks the run
        Stop-SPDistributedCacheServiceInstance -Graceful -Timeout $TimeoutSeconds | Out-Host
        Remove-SPDistributedCacheServiceInstance | Out-Host
        return $true
    }
    catch
    {
        $_ | Out-Host
        Write-Host -ForegroundColor Yellow "Graceful stopping of Cache Host failed. Will fallback to non graceful stop of the caching service."
        return $false
    }
}

function Restore-ServiceState {
    param(
        [PSCustomObject[]]$ServiceStates,
        [bool]$StartServices = $true,
        [int]$TimeoutSeconds = 300
    )

    ## the services are restarted in the reverse order to the order in which they were stopped
    $reversedStates = @($ServiceStates.Clone())
    [array]::Reverse($reversedStates)

    foreach ($state in $reversedStates)
    {
        ## a failure restoring one service must not abandon the rest. This function runs from the
        ## finally block and is the only thing standing between an interrupted run and a server left
        ## with its services stopped and disabled, so it carries on and reports rather than throwing
        try
        {
            ## the startup type has to be restored first, a service which is still disabled cannot be started.
            ## restoring the startup type of a stopped service does not start it, so this is safe to do even
            ## while an installation is still running
            if ($state.StartModeChanged)
            {
                Write-Host "Restoring startup type of $($state.Name) to $($state.StartMode)..."
                Set-ServiceStartMode -Name $state.Name -StartMode $state.StartMode -DelayedStart $state.DelayedStart

                ## clear the flag so that this function can safely be called more than once
                $state.StartModeChanged = $false
            }

            if (!$StartServices)
            {
                continue
            }

            ## a service which was not running before the installation is deliberately left stopped
            if (!$state.WasRunning)
            {
                continue
            }

            ## only the instance this run unprovisioned is provisioned again. Keying on the request
            ## rather than on what was done would call Add-SPDistributedCacheServiceInstance against a
            ## still-provisioned instance whenever the run was abandoned before the cache was reached -
            ## the caching service is the last one stopped, so that is every abort in the stop loop
            if ($state.Unprovisioned)
            {
                Write-Host "Add SPDistributedCacheServiceInstance"
                Add-SPDistributedCacheServiceInstance | Out-Host

                ## cleared for the same reason StartModeChanged is, so that this function can safely be
                ## called more than once
                $state.Unprovisioned = $false
                continue
            }

            ## refresh the cached service object so that the status reflects the state after the installation
            $state.Service.Refresh()

            if ($state.Service.Status -ne "Running")
            {
                Write-Host "Start $($state.Name) service..."
                $state.Service.Start()

                ## the patch has already been applied by this point, so a service which is slow to come
                ## back is reported and the remaining services are still restored
                if (!(Wait-ForServiceStatus -Service $state.Service -Status "Running" -TimeoutSeconds $TimeoutSeconds))
                {
                    Write-Host -ForegroundColor Red "$($state.Name) did not reach the Running state within $TimeoutSeconds seconds. It may still be starting - check it manually."
                }
            }
        }
        catch
        {
            Write-Host -ForegroundColor Red "Restoring $($state.Name) failed:"
            $_ | Out-Host
            Write-Host -ForegroundColor Red "Continuing with the remaining services. $($state.Name) has to be checked manually."
        }
    }
}


# collect the current state of every service so that it can be put back exactly as it was found
$ServiceStates = @()

foreach ($definition in $ServiceDefinitions)
{
    $state = Get-ServiceState $definition

    if ($null -ne $state)
    {
        $ServiceStates += $state
    }
}

$servicesToStop = @($ServiceStates | Where-Object { $_.WasRunning })
$servicesToDisable = @($ServiceStates | Where-Object { $null -ne $_.StartMode -and $_.StartMode -ne "Disabled" })

Write-Host -ForegroundColor Yellow "Warning: This script will stop the following services before applying the fix:"
foreach ($state in $servicesToStop)
{
    Write-Host -ForegroundColor Yellow "- $($state.Name)"
}

Write-Host -ForegroundColor Yellow ""
Write-Host -ForegroundColor Yellow "The startup type of the following services will be set to Disabled for the duration of the"
Write-Host -ForegroundColor Yellow "installation and restored to its current value afterwards:"
foreach ($state in $servicesToDisable)
{
    Write-Host -ForegroundColor Yellow "- $($state.Name) (currently $($state.StartMode))"
}

Write-Host -ForegroundColor Yellow ""

## the operator is told what the caching service is in for before confirming. Whether this server
## actually hosts the distributed cache is established at the point of stopping it rather than here,
## so that the farm is queried once, after the confirmation, and not at all on a server which is not
## running the caching service
$gracefulCandidate = @($ServiceStates | Where-Object { $_.Graceful -and $_.WasRunning })

if ($gracefulCandidate.Count -gt 0)
{
    if ($ShouldGracefulStopDCache)
    {
        Write-Host -ForegroundColor Yellow "If this server hosts the distributed cache, its cached data will be handed to another host and"
        Write-Host -ForegroundColor Yellow "the service instance will be unprovisioned and provisioned again once the patch is applied. If it"
        Write-Host -ForegroundColor Yellow "does not host the distributed cache, $($gracefulCandidate[0].Name) is stopped and restarted like any other service."
    }
    else
    {
        Write-Host -ForegroundColor Yellow "The graceful shutdown was turned off, so $($gracefulCandidate[0].Name) will be stopped outright. If this server"
        Write-Host -ForegroundColor Yellow "hosts the distributed cache, the data held in that cache is lost."
    }

    Write-Host -ForegroundColor Yellow ""
}

if ($Force)
{
    Write-Host -ForegroundColor Yellow "-Force was specified, so the confirmation prompt is skipped."
}
else
{
    Read-Host "PRESS ENTER TO CONTINUE"
}


## $installExitCode is only overwritten once the installer has actually reported a result, so an
## interrupted or failed run is reported to the caller as a failure
$installExitCode = 1
$Process = $null

## everything which changes the state of the machine runs inside this try/finally so that the startup
## types are put back even if the script is interrupted or the installation throws
try
{
    foreach ($state in $ServiceStates)
    {
        $useGracefulStop = ($state.Graceful -and $state.WasRunning -and $ShouldGracefulStopDCache)

        ## the distributed cache is shut down through the SharePoint cmdlets before its startup type is
        ## changed, because unprovisioning the service instance of a disabled service fails
        if ($useGracefulStop)
        {
            if (Stop-DistributedCacheGracefully -State $state -TimeoutSeconds $ServiceTimeoutSeconds)
            {
                ## the instance is now unprovisioned, so the finally block owes the farm an
                ## Add-SPDistributedCacheServiceInstance
                $state.Unprovisioned = $true
            }
            else
            {
                ## either this server does not host the distributed cache or the graceful shutdown
                ## failed - fall back to simply stopping the service
                $useGracefulStop = $false
            }
        }

        ## disabling the service stops the installer and any Service Control Manager recovery action from
        ## restarting it while the patch is being applied. This happens before the service is stopped so
        ## that there is no window in which a recovery action can bring it back up.
        if ($null -eq $state.StartMode)
        {
            Write-Host -ForegroundColor Yellow "The startup type of $($state.Name) could not be determined and will be left unchanged."
        }
        elseif ($state.StartMode -ne "Disabled")
        {
            Write-Host "Setting startup type of $($state.Name) to Disabled..."
            Set-ServiceStartMode -Name $state.Name -StartMode "Disabled"
            $state.StartModeChanged = $true
        }

        if (!$useGracefulStop)
        {
            ## a service which will not stop must not be ignored. The installer would then run against a
            ## service which still holds its file locks, which is the whole problem this script exists to
            ## avoid, so the run is abandoned and the finally block puts the startup types back
            if (!(Stop-ServiceIfRunning -State $state -TimeoutSeconds $ServiceTimeoutSeconds))
            {
                throw "$($state.Name) could not be stopped, so the installation has not been started."
            }
        }
    }

    Write-Host
    Write-Host -ForegroundColor Green "All relevant Services have been stopped."
    Write-Host -ForegroundColor Green "The SharePoint CU will now be applied..."

    $startTime = Get-Date

    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = $CULocation
    $pInfo.Arguments = "/passive"

    $Process = [Diagnostics.Process]::Start($pInfo)

    $afterLaunchTime = Get-Date

    $delta = $afterLaunchTime - $startTime

    Write-Host
    Write-Host "Fix installation has been initiated. Waiting for completion..."
    Write-Host -ForegroundColor Green "Time taken to launch installer: $(Format-Duration $delta)"

    while (!$Process.HasExited)
    {
        Start-Sleep -seconds 1
    }

    ## we cannot use $Process.WaitForExit as it does not work reliably.
    ## In my tests it did not return even after the process ended in several tests
    ## Need to loop and check HasExited instead

    $endTime = Get-Date

    $delta = $endTime - $afterLaunchTime

    # capture the exit code so that it can be returned to the caller once the services have been restarted
    $installExitCode = $Process.ExitCode

    # check if the installation succeeded and report back
    if ($installExitCode -eq 0)
    {
        Write-Host
        Write-Host -ForegroundColor Green "Fix installation completed."
        Write-Host -ForegroundColor Green "Time taken to install fix: $(Format-Duration $delta)"
        Write-Host
    }
    elseif ($installExitCode -eq 17022)
    {
        Write-Host
        Write-Host -ForegroundColor Yellow "Fix installation completed, but a reboot is required to complete the installation.`nPlease reboot the server as soon as possible.`n"
        Write-Host -ForegroundColor Yellow "Time taken to install fix: $(Format-Duration $delta)"
        Write-Host
    }
    else
    {
        Write-Host
        Write-Host -ForegroundColor Red $(Get-ExitMessage $installExitCode)
        Write-Host
    }
}
catch
{
    Write-Host
    Write-Host -ForegroundColor Red "The installation was not completed because of an unexpected error:"
    $_ | Out-Host
    Write-Host
}
finally
{
    ## if the script was interrupted while the installer was still running then the services must not be
    ## started again - doing so would put the file locks back while the patch is still being applied
    $installerStillRunning = ($null -ne $Process -and !$Process.HasExited)

    if ($installerStillRunning)
    {
        Write-Host
        Write-Host -ForegroundColor Red "The script was interrupted while the installation was still running."
        Write-Host -ForegroundColor Red "The startup types will be restored but the services will NOT be started, because"
        Write-Host -ForegroundColor Red "starting them now would interfere with the installation which is still in progress."
        Write-Host -ForegroundColor Red "Start them manually once the installation has finished, or reboot the server."

        ## the caching service is the one service which must not be started by hand. Its instance was
        ## unprovisioned, and Microsoft is explicit that the only supported way to bring it back is
        ## Add-SPDistributedCacheServiceInstance - starting the service directly leaves the farm with a
        ## cache host SharePoint does not know about
        foreach ($state in @($ServiceStates | Where-Object { $_.Unprovisioned }))
        {
            Write-Host -ForegroundColor Red ""
            Write-Host -ForegroundColor Red "$($state.Name) is the exception: this server hosts the distributed cache and its service"
            Write-Host -ForegroundColor Red "instance has been unprovisioned. Do NOT start $($state.Name) by hand. Once the installation has"
            Write-Host -ForegroundColor Red "finished, run Add-SPDistributedCacheServiceInstance on this server instead."
        }

        Write-Host
    }

    Restore-ServiceState -ServiceStates $ServiceStates -StartServices (!$installerStillRunning) -TimeoutSeconds $ServiceTimeoutSeconds

    Write-Host
    Write-Host -ForegroundColor Green "Service restart completed."
}

# return the result of the patch installation to the caller so that failures can be detected by automation
Exit $installExitCode
