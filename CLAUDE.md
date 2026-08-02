# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single PowerShell script, `Install-SPSE_Fix.ps1`, forked from Stefan Goßner's original
(`upstream` = `https://github.com/stefangossner/Install-SPSE_Fix.git`, unmodified at v1.6). It cuts
the install time of a SharePoint Server Subscription Edition cumulative update by stopping the
SharePoint/IIS services that hold file locks, applying the CU, then putting everything back.
Rationale: <https://blog.stefan-gossner.com/2024/03/08/solving-the-extended-install-time-for-spse-cus/>

The script is at **version 1.7**, which is what its comment header documents. `README.md` covers
purpose, usage, parameters and exit codes; `tests/README.md` covers what the tests do and — more
importantly — what has and has not been verified, including against a real CU on a real farm.

There is no separate backlog: the v1.7 batch is complete and the handover document that tracked it
has been retired. Untested paths are listed under "Still never tested anywhere" in
`tests/README.md`.

## Commands

```powershell
.\tests\Test-Logic.ps1          # unit tests  - functions extracted from the real script via the AST
.\tests\Test-Integration.ps1    # end-to-end  - real script run in a child powershell.exe per scenario
```

Each exits with the number of failed assertions, so `$LASTEXITCODE -eq 0` means everything passed.
There is no build, lint, or package step. Run both after any change to `Install-SPSE_Fix.ps1`.

To run a single case, comment out the other `Check` calls or the other `Invoke-Scenario` blocks —
there is no test framework and no filtering (Pester is not used).

Neither harness touches a real service or executes an installer; every service cmdlet is stubbed and
the one `[Diagnostics.Process]::Start` call is textually replaced. Scratch files go to
`%TEMP%\spse-cu-tests`.

## Target environment

- **Windows PowerShell 5.1**, not PowerShell 7 — that is what the SharePoint Management Shell uses,
  and SharePoint SE cmdlets are unsupported on 7. `Test-Integration.ps1` spawns `powershell.exe`, so
  it is Windows-only by design.
- The script is `#Requires -RunAsAdministrator`.
- The `-ShouldGracefulStopDCache $true` path only works from the SharePoint Management Shell (see
  pending fix #2 — the script does not load the `Microsoft.SharePoint.PowerShell` snap-in itself).

## Architecture

The script is table-driven around `$ServiceDefinitions` — an ordered list of the seven services
(`SPTimerV4`, `SPTraceV4`, `SPAdminV4`, `W3SVC`, `OSearch16`, `SPSearchHostController`, `SPCache`).
They are stopped in list order and restarted in the exact reverse. `SPCache` is flagged `Graceful`,
marking it as the distributed cache host.

Flow: `Get-ServiceState` snapshots each service into a `[PSCustomObject]` (`WasRunning`, `StartMode`,
`DelayedStart`, `StartModeChanged`) → the plan is printed and confirmed → a single `try`/`catch`/
`finally` wraps everything that mutates the machine → `Restore-ServiceState` in the `finally` puts it
all back.

Invariants that are easy to break — preserve them:

- **Disable before stop.** Setting startup type to `Disabled` precedes stopping the service, so no
  Service Control Manager recovery action can revive it mid-patch. `SPCache` on the graceful path is
  the sole exception: it is unprovisioned *before* being disabled, because unprovisioning a disabled
  service instance fails.
- **Restore the original startup type, never a blanket `Automatic`.** A `Manual` service goes back to
  `Manual`. Startup type is read via `Get-CimInstance Win32_Service` rather than
  `ServiceController.StartType` because only the former exposes `DelayedAutoStart`; `Set-Service`
  cannot express "Automatic (Delayed Start)", so that flag is written directly to
  `HKLM:\SYSTEM\CurrentControlSet\Services\<name>\DelayedAutostart`.
- **Only touch what was ours to touch.** `StartModeChanged` gates the restore and is cleared on
  restore, making `Restore-ServiceState` idempotent. A service whose startup type could not be
  determined is warned about and left alone. A service not installed on this server's role is skipped
  silently, not reported as an error. A service that was already stopped is disabled but never
  started.
- **If the installer is still running when `finally` runs**, startup types are restored but services
  are **not** started — starting them would restore the file locks mid-patch. Restoring a stopped
  service's startup type does not start it, so that half is always safe.
- **Exit codes are the caller's contract.** `Exit $installExitCode` propagates the installer's code
  verbatim; 17022 ("installed, reboot required") is deliberately *not* flattened to 0. `1` means the
  path was invalid or the run was interrupted before the installer reported. Known codes are in
  `$ErrorMap`.
- The installer wait loops on `$Process.HasExited` rather than `WaitForExit()`, which was found not to
  return reliably.

## Conventions

- Version history lives in the comment header of `Install-SPSE_Fix.ps1`. The current batch of work is
  pinned to **1.7** — append to the existing 1.7 block rather than bumping the version per fix.
- Behaviour carried over unchanged from upstream that is known to be wrong is marked with a `NOTE:`
  comment rather than silently fixed, so untestable changes don't ride along with refactors.
- Off-farm tests cannot cover `Set-Service`, the registry write, the AppFabric/SharePoint cmdlets, a
  real patch install, or a real Ctrl-C. What that leaves unverified is listed under "Still never
  tested anywhere" in `tests/README.md` — read it before assuming a path is safe.
