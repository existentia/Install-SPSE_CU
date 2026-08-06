# End-to-end tests for Install-SPSE_Fix.ps1.
#
# Builds a runnable copy of the script in the temp directory and runs it in a child process, once
# per scenario. Exactly three edits are made to the shipped script:
#   1. the #Requires -RunAsAdministrator line is dropped
#   2. the stubs in Stubs.ps1 are injected directly after the param() block
#   3. the single [Diagnostics.Process]::Start call is swapped for a fake
# Everything else - the whole stop / install / restore control flow - is the real code.
#
# SAFETY: no real service is touched and no installer is executed. See the header of Stubs.ps1.
#
# Run:  .\tests\Test-Integration.ps1  (Windows PowerShell 5.1, on the SharePoint server)
# Exits with the number of failed assertions.

$repoRoot   = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "Install-SPSE_Fix.ps1"

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "spse-cu-tests"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$patched = Join-Path $workDir "patched.ps1"
$fakeCU  = Join-Path $workDir "fake-cu.exe"
$log     = Join-Path $workDir "run.log"

Set-Content -Path $fakeCU -Value "not a real installer"

# Windows PowerShell 5.1 is what the SharePoint Management Shell uses, and is the engine the
# script actually targets, so the child process is run under it
$shell = "powershell"

$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

# use the text the parser saw, so the AST offsets below line up regardless of any byte order mark
$src = $ast.Extent.Text

# the stubs have to go after param(), a param block is only valid at the top of a script
$paramEnd = $ast.ParamBlock.Extent.EndOffset
$head = $src.Substring(0, $paramEnd) -replace '(?m)^#Requires .*$', ''
$tail = $src.Substring($paramEnd)

$tailFaked = $tail -replace '\[Diagnostics\.Process\]::Start\(\$pInfo\)', '(New-FakeProcess)'
if ($tailFaked -eq $tail) { throw "the Process::Start substitution did not match - the harness needs updating" }

$prelude = Get-Content (Join-Path $PSScriptRoot "Stubs.ps1") -Raw
Set-Content -Path $patched -Value ($head + "`r`n`r`n" + $prelude + "`r`n" + $tailFaked)

$pass = 0; $fail = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:pass++; Write-Host "    PASS  $label" -ForegroundColor Green }
    else { $script:fail++; Write-Host "    FAIL  $label`n            expected: $expected`n            actual:   $actual" -ForegroundColor Red }
}

function Invoke-Scenario {
    param($Scenario, $InstallerExit = 0, $HangService = "", [string[]]$ExtraArgs = @(), $DCacheRunning = $false, $DCacheHost = "")

    Remove-Item $log -ErrorAction SilentlyContinue

    $env:TESTLOG = $log
    $env:SCENARIO = $Scenario
    $env:INSTALLER_EXIT = $InstallerExit

    ## always set, so that one scenario cannot leak state into the next
    $env:HANG_SERVICE = $HangService
    $env:DCACHE_RUNNING = $(if ($DCacheRunning) { "1" } else { "" })
    $env:DCACHE_HOST = $DCacheHost

    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $patched -CULocation $fakeCU @ExtraArgs 2>&1
    $code = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $code
        Lines    = @(if (Test-Path $log) { Get-Content $log } else { @() })
        Output   = ($out -join "`n")
    }
}

function IndexOf($lines, $entry) { return [array]::IndexOf($lines, $entry) }
function CountMatching($lines, $pattern) { return @($lines | Where-Object { $_ -match $pattern }).Count }

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: installation succeeds"
$r = Invoke-Scenario -Scenario "ok" -InstallerExit 0
$l = $r.Lines
Check "exit code is 0"                             0      $r.ExitCode
Check "startup type disabled before the stop"      $true  ((IndexOf $l "SETMODE SPTimerV4 -> Disabled") -lt (IndexOf $l "STOP SPTimerV4"))
Check "running services were stopped"              $true  ($l -contains "STOP W3SVC")
Check "running services were started again"        $true  ($l -contains "START W3SVC")
Check "Auto restored for a running service"        $true  ($l -contains "SETMODE SPTimerV4 -> Automatic")
Check "delayed start flag preserved for W3SVC"     $true  ($l -contains "REG W3SVC\DelayedAutostart = 1")
Check "delayed start flag cleared for SPAdminV4"   $true  ($l -contains "REG SPAdminV4\DelayedAutostart = 0")
Check "stopped Manual service was disabled"        $true  ($l -contains "SETMODE OSearch16 -> Disabled")
Check "stopped Manual service restored to Manual"  $true  ($l -contains "SETMODE OSearch16 -> Manual")
Check "stopped service was NOT started"            $false ($l -contains "START OSearch16")
Check "already-disabled service left untouched"    $false (($l -join "`n") -match "SPCache")
Check "uninstalled service skipped silently"       $false ($r.Output -match "SPSearchHostController")
Check "every disabled service was restored"        (CountMatching $l "-> Disabled") (CountMatching $l "-> (Automatic|Manual)")
Check "restart happens in reverse order"           $true  ((IndexOf $l "SETMODE OSearch16 -> Manual") -lt (IndexOf $l "SETMODE SPTimerV4 -> Automatic"))
Check "the operator was asked to confirm"          $true  ($l -contains "PROMPT")
Check "nothing was changed before the prompt"      $true  ((IndexOf $l "PROMPT") -lt (IndexOf $l "SETMODE SPTimerV4 -> Disabled"))

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: installer reports a failure (17302)"
$r = Invoke-Scenario -Scenario "ok" -InstallerExit 17302
$l = $r.Lines
Check "failure exit code propagated"                17302 $r.ExitCode
Check "services still restarted after a failure"    $true ($l -contains "START SPTimerV4")
Check "startup types still restored after failure"  $true ($l -contains "SETMODE SPTimerV4 -> Automatic")
Check "failure message shown"                       $true ($r.Output -match "The installation of the patch failed")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: installer fails to launch"
$r = Invoke-Scenario -Scenario "launchfail"
$l = $r.Lines
Check "exit code is 1"                              1     $r.ExitCode
Check "error reported to the operator"              $true ($r.Output -match "unexpected error")
Check "startup types restored"                      $true ($l -contains "SETMODE SPTimerV4 -> Automatic")
Check "services restarted (installer never ran)"    $true ($l -contains "START SPTimerV4")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: interrupted while the installer is still running"
$r = Invoke-Scenario -Scenario "interrupted"
$l = $r.Lines
Check "exit code is 1"                              1     $r.ExitCode
Check "startup types ARE restored"                  $true ($l -contains "SETMODE SPTimerV4 -> Automatic")
Check "every disabled service was restored"         (CountMatching $l "-> Disabled") (CountMatching $l "-> (Automatic|Manual)")
Check "services NOT started mid-install"            $false ($l -contains "START SPTimerV4")
Check "operator warned to start them manually"      $true ($r.Output -match "Start them manually")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: a service will not stop"
$r = Invoke-Scenario -Scenario "ok" -HangService "SPTraceV4"
$l = $r.Lines
Check "exit code is 1"                              1     $r.ExitCode
Check "the wait was bounded, not hung"              $true ($l -contains "TIMEOUT SPTraceV4 waiting for Stopped")
Check "the installer was NEVER launched"            $false ($l -contains "LAUNCH installer")
Check "the failing service is named"                $true ($r.Output -match "SPTraceV4 did not stop within")
Check "startup type of the failing service restored" $true ($l -contains "SETMODE SPTraceV4 -> Automatic")
Check "startup type of the earlier service restored" $true ($l -contains "SETMODE SPTimerV4 -> Automatic")
Check "every disabled service was restored"         (CountMatching $l "-> Disabled") (CountMatching $l "-> (Automatic|Manual)")
Check "the already-stopped service was restarted"   $true ($l -contains "START SPTimerV4")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: unattended run with -Force"
$r = Invoke-Scenario -Scenario "ok" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "the confirmation prompt was skipped"         $false ($l -contains "PROMPT")
Check "the installation still ran"                  $true  ($l -contains "LAUNCH installer")
Check "services were still restored"                $true  ($l -contains "SETMODE SPTimerV4 -> Automatic")

# ---------------------------------------------------------------------------------------------
# the graceful path is on by default, so this passes no switch at all
Write-Host "`nScenario: graceful distributed cache shutdown on a real cache host"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "the graceful path is on by default"          $true  ($l -contains "DCACHE STOP graceful=True timeout=300")
Check "the role was confirmed with the farm"        $true  ($l -contains "DCACHE GETINSTANCE")
Check "the role was checked before anything ran"    $true  ((IndexOf $l "DCACHE GETINSTANCE") -lt (IndexOf $l "DCACHE USECLUSTER"))
Check "the instance was unprovisioned"              $true  ($l -contains "DCACHE REMOVE")
Check "the instance was provisioned again"          $true  ($l -contains "DCACHE ADD")
Check "the cache was not stopped as a plain service" $false ($l -contains "STOP SPCache")
Check "unprovision precedes disabling"              $true  ((IndexOf $l "DCACHE REMOVE") -lt (IndexOf $l "SETMODE SPCache -> Disabled"))

# ---------------------------------------------------------------------------------------------
# the v1.7 call site: passing the switch explicitly still means the same thing
Write-Host "`nScenario: -ShouldGracefulStopDCache passed explicitly still works"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force", "-ShouldGracefulStopDCache")
$l = $r.Lines
Check "exit code is 0"                              0     $r.ExitCode
Check "the graceful path still engaged"             $true ($l -contains "DCACHE REMOVE")
Check "and the instance came back"                  $true ($l -contains "DCACHE ADD")

# ---------------------------------------------------------------------------------------------
# THE CASE THIS EXISTS FOR: the caching service is running, but the farm says this server is not a
# distributed cache host. No distributed cache cmdlet may touch it.
Write-Host "`nScenario: SPCache is running but this server is NOT a cache host"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "the farm was asked about the role"           $true  ($l -contains "DCACHE GETINSTANCE")
Check "the cache cluster was never entered"         $false ($l -contains "DCACHE USECLUSTER")
Check "Stop-SPDistributedCache... never ran"        0      (CountMatching $l "DCACHE STOP")
Check "Remove-SPDistributedCache... never ran"      $false ($l -contains "DCACHE REMOVE")
Check "Add-SPDistributedCache... never ran"         $false ($l -contains "DCACHE ADD")
Check "it was stopped as a plain service"           $true  ($l -contains "STOP SPCache")
Check "and restarted as a plain service"            $true  ($l -contains "START SPCache")
Check "the operator was told why"                   $true  ($r.Output -match "does not host the distributed cache")

# ---------------------------------------------------------------------------------------------
# an instance exists for this server but is not Online - unprovisioning it is neither needed nor safe
Write-Host "`nScenario: the cache service instance is registered but not Online"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "offline" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "no distributed cache cmdlet ran"             0      (CountMatching $l "DCACHE (USECLUSTER|STOP|REMOVE|ADD)")
Check "it was stopped as a plain service"           $true  ($l -contains "STOP SPCache")
Check "the status is reported"                      $true  ($r.Output -match "is Disabled rather than Online")

# ---------------------------------------------------------------------------------------------
# the role check has to fail closed: an unreachable farm is not evidence that this is a cache host
Write-Host "`nScenario: the farm cannot be reached for the role check"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "throw" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "the run was not aborted"                     $true  ($l -contains "LAUNCH installer")
Check "no distributed cache cmdlet ran"             0      (CountMatching $l "DCACHE (USECLUSTER|STOP|REMOVE|ADD)")
Check "it fell back to a plain stop"                $true  ($l -contains "STOP SPCache")
Check "the failure to confirm is reported"          $true  ($r.Output -match "could not be read")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: opting out with -NoGracefulStopDCache"
$r = Invoke-Scenario -Scenario "ok" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force", "-NoGracefulStopDCache")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "the farm was not consulted at all"           $false ($l -contains "DCACHE GETINSTANCE")
Check "no distributed cache cmdlet ran"             0      (CountMatching $l "DCACHE (USECLUSTER|STOP|REMOVE|ADD)")
Check "the cache was stopped outright"              $true  ($l -contains "STOP SPCache")
Check "and restarted as a plain service"            $true  ($l -contains "START SPCache")
Check "the data loss is spelled out beforehand"     $true  ($r.Output -match "the data held in that cache is lost")

# ---------------------------------------------------------------------------------------------
Write-Host "`nScenario: graceful shutdown fails and falls back"
$r = Invoke-Scenario -Scenario "dcachefail" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 0"                              0      $r.ExitCode
Check "it fell back to a plain stop"                $true  ($l -contains "STOP SPCache")
Check "the cache was restarted as a service"        $true  ($l -contains "START SPCache")
Check "it did not try to provision the instance"    $false ($l -contains "DCACHE ADD")
Check "the fallback was reported"                   $true  ($r.Output -match "fallback to non graceful stop")

# ---------------------------------------------------------------------------------------------
# the caching service is stopped last, so any abort in the stop loop happens with the cache instance
# still provisioned. Add-SPDistributedCacheServiceInstance must not run against it.
Write-Host "`nScenario: aborted before the cache was reached, on a cache host"
$r = Invoke-Scenario -Scenario "ok" -HangService "SPTraceV4" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 1"                              1      $r.ExitCode
Check "the cache was never unprovisioned"           $false ($l -contains "DCACHE REMOVE")
Check "so it was NOT provisioned on the way out"    $false ($l -contains "DCACHE ADD")
Check "the cache service was left running"          $false ($l -contains "STOP SPCache")
Check "every disabled service was restored"         (CountMatching $l "-> Disabled") (CountMatching $l "-> (Automatic|Manual)")

# ---------------------------------------------------------------------------------------------
# interrupted after the instance was unprovisioned: it cannot be provisioned again while the
# installer is still running, so the operator has to be told what to run afterwards
Write-Host "`nScenario: interrupted after the cache was unprovisioned"
$r = Invoke-Scenario -Scenario "interrupted" -DCacheRunning $true -DCacheHost "online" -ExtraArgs @("-Force")
$l = $r.Lines
Check "exit code is 1"                              1      $r.ExitCode
Check "the instance really was unprovisioned"       $true  ($l -contains "DCACHE REMOVE")
Check "it was NOT provisioned mid-install"          $false ($l -contains "DCACHE ADD")
Check "the cache startup type was restored"         $true  ($l -contains "SETMODE SPCache -> Automatic")
Check "the operator is told not to start it"        $true  ($r.Output -match "Do NOT start SPCache by hand")
Check "and what to run instead"                     $true  ($r.Output -match "run Add-SPDistributedCacheServiceInstance on this server")

# ---------------------------------------------------------------------------------------------
# the CU path is rejected as it is bound, so these run the script directly rather than a scenario
Write-Host "`nScenario: the CU path is rejected before anything runs"

$missing = Join-Path $workDir "no-such-update.exe"
$out = & $shell -NoProfile -ExecutionPolicy Bypass -File $patched -CULocation $missing 2>&1
Check "a missing file exits 1"                      1      $LASTEXITCODE
Check "the missing file is reported"                $true  (($out -join "`n") -match "was not found")

$notAnExe = Join-Path $workDir "update.txt"
Set-Content -Path $notAnExe -Value "not an installer"
$out = & $shell -NoProfile -ExecutionPolicy Bypass -File $patched -CULocation $notAnExe 2>&1
Check "a non-exe exits 1"                           1      $LASTEXITCODE
Check "the wrong file type is reported"             $true  (($out -join "`n") -match "has to be an .exe")

Write-Host "`n$pass passed, $fail failed" -ForegroundColor $(if ($fail) { "Red" } else { "Green" })
exit $fail
