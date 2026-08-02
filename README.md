# Install-SPSE_Fix

Cuts the install time of a SharePoint Server Subscription Edition cumulative update by stopping the
services that hold file locks, applying the patch, and putting everything back exactly as it was.

A CU that takes hours largely does so because running SharePoint and IIS services hold file locks and
trigger repeated installer retry logic. Stopping them first turns a multi-hour install into a much
shorter one. The reasoning is Stefan Goßner's:
<https://blog.stefan-gossner.com/2024/03/08/solving-the-extended-install-time-for-spse-cus/>

This is a fork of [Stefan Goßner's original](https://github.com/stefangossner/Install-SPSE_Fix),
carrying additional fixes — see [Version 1.7](#version-17) below. Upstream was last matched at 1.6. To
diff against it:

```powershell
git remote add upstream https://github.com/stefangossner/Install-SPSE_Fix.git
```

## Requirements

- **SharePoint Server Subscription Edition.** The script targets SPSE specifically; it uses the
  `SharePointServer` module, which SPSE puts on `PSModulePath`.
- **Windows PowerShell 5.1** — the engine the SharePoint Management Shell uses. SharePoint SE cmdlets
  are not supported on PowerShell 7.
- **Run as Administrator** (`#Requires -RunAsAdministrator`).
- A plain elevated `powershell.exe` is enough. The SharePoint Management Shell is *not* required, even
  for the graceful distributed cache path.

## Usage

```powershell
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\uber-subscription-kb5002560-fullfile-x64-glb.exe
```

The script prints exactly what it intends to do — which services it will stop, and each one's current
startup type — and waits for confirmation before changing anything.

Unattended, for driving across a farm:

```powershell
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -Force
```

On a server that hosts distributed cache, to hand the cached data over to another host first:

```powershell
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -ShouldGracefulStopDCache
```

### Always capture a transcript

The console output records each service's original startup type **before** anything is changed. If a
run is interrupted, that output is your recovery data.

```powershell
Start-Transcript -Path C:\temp\spse-cu.log
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe
Stop-Transcript
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-CULocation` | string | *required* | Path to the CU executable. Relative paths are allowed. Validated as it is bound, so a bad path fails immediately with exit code 1. |
| `-ShouldGracefulStopDCache` | switch | off | Hand the distributed cache's data to another host before stopping, instead of stopping the service outright. Only has an effect if this server runs a *running* `SPCache`. If the graceful shutdown fails, the script falls back to a plain stop. |
| `-ServiceTimeoutSeconds` | int | `300` | How long to wait for a single service to stop or start, and for the graceful cache shutdown. **Per service**, not for the run as a whole. |
| `-Force` | switch | off | Skip the confirmation prompt. Required for unattended runs. |

## Exit codes

The script returns the patch installer's own exit code, so automation can evaluate the outcome.

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | The CU path was not valid, or the run was interrupted or aborted before the installer reported. |
| `17022` | Installed successfully, **but a reboot is required.** Deliberately not flattened to 0. |
| `17025` | The update is already installed on this system. |
| `17028` | There are no products affected by this package installed on this system. |
| `-1`, `17302` | The installation of the patch failed. |
| `17021`, `17300` | An error occurred during the installation of this fix. |
| `17301`, `17030` | Detection failed — possibly a corrupted installation database. |
| `17303` | An error occurred while extracting the files from this package. |
| `17023` | The installation of this package was cancelled. |
| `17032` | Insufficient disk space to install the fix. |

For automation, treat **`0` and `17022`** as "the patch is applied" — `17022` simply means the server
still needs rebooting. `17025` is nonzero but usually just means the CU was already applied, which
matters if you re-run across a farm.

## What it actually does

These services are stopped in this order, and restarted in the exact reverse:

`SPTimerV4` → `SPTraceV4` → `SPAdminV4` → `W3SVC` → `OSearch16` → `SPSearchHostController` → `SPCache`

The behaviour worth knowing about:

- **Startup type is set to `Disabled` before each service is stopped**, and restored afterwards. This
  stops both the installer and any Service Control Manager recovery action from restarting a service
  mid-patch. Disabling happens *before* the stop, so there is no window for a recovery action to
  revive it.
- **The original startup type is restored, not a blanket `Automatic`.** A `Manual` service goes back to
  `Manual`, and `Automatic (Delayed Start)` keeps its delayed flag.
- **Only services that were running beforehand are restarted.** A service an administrator had
  deliberately stopped stays stopped.
- **Services not installed on this server's role are skipped silently** — no errors on a role that has
  no Search, for instance.
- **Startup types are restored even if the run fails, throws, or is interrupted**, from a `finally`
  block. If the installer is still running at that point, startup types are restored but the services
  are *not* started — starting them mid-patch would put the file locks back. You are told to start
  them manually.
- **A service that will not stop aborts the run.** Patching while a service still holds its file locks
  defeats the purpose, so nothing is installed and the startup types are put back.

### If the PowerShell process is killed outright

A forced termination — Task Manager, `taskkill`, closing the console window — cannot be intercepted.
If that happens between the services being disabled and the installation finishing, they are left
stopped and disabled.

To recover: wait for the installation to finish, then put the startup types back and start the
services this server's role requires. The original values are in the console output (hence the
transcript). Check them against another server in the farm first — not every service is `Automatic` on
every role, so a blanket reset to `Automatic` is not necessarily correct.

## Version 1.7

Fixes on top of upstream 1.6:

- Durations of an hour or more are reported correctly (`TimeSpan.Minutes` wraps at 60, so a 1-hour
  install used to report "0 Minutes, 0 Seconds").
- The installer's exit code is returned to the caller, so automation can detect a failed patch. The
  script previously always exited 0.
- Startup types are set to `Disabled` for the duration of the install and restored afterwards.
- Only services that were running beforehand are restarted, and each gets its *original* startup type
  back rather than a blanket `Automatic`.
- Services not installed on the server are skipped rather than reported as errors.
- Restoration runs from a `finally` block, so a failed, cancelled or aborted install cannot leave the
  services stopped and disabled.
- Every wait is bounded (`-ServiceTimeoutSeconds`). `WaitForStatus` previously had no timeout, so a
  wedged service hung the script indefinitely — and a hang can only be escaped by killing the process,
  which is the one case the `finally` block cannot recover from.
- The graceful distributed cache shutdown no longer imports a module by a hardcoded path or hardcodes
  the cache port, and no longer has to be run from the SharePoint Management Shell.
- `-Force` for unattended execution, and `-CULocation` is validated as it is bound.

### ⚠ Breaking change

`-ShouldGracefulStopDCache` is now a `[switch]`, not a `[bool]`:

```powershell
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -ShouldGracefulStopDCache        # 1.7
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -ShouldGracefulStopDCache $true  # 1.6 and earlier
```

The old form fails loudly rather than doing the wrong thing — PowerShell reads `$true` as a positional
argument, and the run aborts with `A positional parameter cannot be found that accepts argument
'True'` and exit code 1. Anything scripted against the 1.6 signature needs updating. Note that the
blog post linked above uses the old form.

## Tests

An off-farm test harness lives in [`tests/`](tests/). It touches no real service, executes no
installer, and acts on no real cache cluster — everything is stubbed.

```powershell
.\tests\Test-Logic.ps1
.\tests\Test-Integration.ps1
```

Each exits with the number of failed assertions, so `$LASTEXITCODE -eq 0` means everything passed. Run
both after any change. See [`tests/README.md`](tests/README.md) for what is and is not covered.

## Disclaimer

This is sample code, provided as-is and without warranty of any kind. The full disclaimer is in the
header of `Install-SPSE_Fix.ps1` and applies to this fork as it did to the original. Test on a
non-production farm first.
