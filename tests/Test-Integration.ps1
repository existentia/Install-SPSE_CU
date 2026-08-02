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
    param($Scenario, $InstallerExit = 0)

    Remove-Item $log -ErrorAction SilentlyContinue

    $env:TESTLOG = $log
    $env:SCENARIO = $Scenario
    $env:INSTALLER_EXIT = $InstallerExit

    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $patched -CULocation $fakeCU 2>&1
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

Write-Host "`n$pass passed, $fail failed" -ForegroundColor $(if ($fail) { "Red" } else { "Green" })
exit $fail
