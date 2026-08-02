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
    [Parameter(Mandatory=$true)]
    [string]$CULocation,

    [Parameter(Mandatory=$false)]
    [bool]$ShouldGracefulStopDCache = $false
)

# allow relative paths to work
$CULocation = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD, $CULocation))

if (!$CULocation.ToLower().EndsWith(".exe") -or ![System.IO.File]::Exists($CULocation))
{
    Write-Host -ForegroundColor Yellow "Please specify the path of the SharePoint Server Subscription Edition Update fix (e.g. C:\temp\uber-subscription-kb5002560-fullfile-x64-glb.exe)"
    Exit 1
}

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

function Stop-ServiceIfRunning {
    param([PSCustomObject]$State)

    if (!$State.WasRunning) {
        return
    }

    Write-Host "Stopping $($State.Name) service..."
    $State.Service.Stop()
    $State.Service.WaitForStatus("Stopped")
}

function Stop-DistributedCacheGracefully {
    param([PSCustomObject]$State)

    ## the output of the cmdlets below is sent straight to the host so that it does not end up
    ## in the return value of this function

    ## NOTE: carried over unchanged from version 1.6 - the import order of the administration module
    ##       and the missing Microsoft.SharePoint.PowerShell snap-in are addressed separately
    Use-SPCacheCluster | Out-Host
    Import-Module "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\16\BIN\CacheModules\DistributedCacheAdministration\DistributedCacheAdministration" | Out-Host
    Get-SPCacheClusterHealth | Out-Host

    try
    {
        Write-Host "Graceful stopping Cache Host..."
        Stop-AFCacheHost -Graceful -ComputerName $env:COMPUTERNAME -CachePort 22233 | Out-Host
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
        [bool]$GracefulDCache = $false,
        [bool]$StartServices = $true
    )

    ## the services are restarted in the reverse order to the order in which they were stopped
    $reversedStates = @($ServiceStates.Clone())
    [array]::Reverse($reversedStates)

    foreach ($state in $reversedStates)
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

        if ($state.Graceful -and $GracefulDCache)
        {
            Write-Host "Add SPDistributedCacheServiceInstance"
            Add-SPDistributedCacheServiceInstance | Out-Host
            continue
        }

        ## refresh the cached service object so that the status reflects the state after the installation
        $state.Service.Refresh()

        if ($state.Service.Status -ne "Running")
        {
            Write-Host "Start $($state.Name) service..."
            $state.Service.Start()
            $state.Service.WaitForStatus("Running")
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
Read-Host "PRESS ENTER TO CONTINUE"


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
            if (!(Stop-DistributedCacheGracefully $state))
            {
                ## the graceful shutdown failed - fall back to simply stopping the service
                $ShouldGracefulStopDCache = $false
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
            Stop-ServiceIfRunning $state
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
        Write-Host
    }

    Restore-ServiceState -ServiceStates $ServiceStates -GracefulDCache $ShouldGracefulStopDCache -StartServices (!$installerStillRunning)

    Write-Host
    Write-Host -ForegroundColor Green "Service restart completed."
}

# return the result of the patch installation to the caller so that failures can be detected by automation
Exit $installExitCode
