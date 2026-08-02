# Handoff — Install-SPSE_Fix.ps1 v1.7

Written for a fresh Claude Code session picking this up on a SharePoint Server Subscription Edition
box. Assume no prior conversation context.

---

## 1. What this repo is

A single PowerShell script, `Install-SPSE_Fix.ps1`, forked from Stefan Goßner's original.

- `origin`   → `https://github.com/existentia/Install-SPSE_CU.git` (this fork)
- `upstream` → `https://github.com/stefangossner/Install-SPSE_Fix.git` (unmodified at v1.6, commit `f52a6c4`)

**What it does.** SharePoint SE cumulative updates take hours largely because running SharePoint and
IIS services hold file locks and trigger repeated installer retry logic. The script stops those
services, applies the CU, then puts everything back. Rationale:
<https://blog.stefan-gossner.com/2024/03/08/solving-the-extended-install-time-for-spse-cus/>

Services handled, in stop order (restart is the exact reverse):
`SPTimerV4`, `SPTraceV4`, `SPAdminV4`, `W3SVC`, `OSearch16`, `SPSearchHostController`, `SPCache`

---

## 2. Environment on the server

- Run **as Administrator** (`#Requires -RunAsAdministrator`).
- Target shell is **Windows PowerShell 5.1** — that's what the SharePoint Management Shell uses, and
  SharePoint SE cmdlets are not supported on PowerShell 7. The script was written for 5.1.
- The `-ShouldGracefulStopDCache` path **no longer requires the SharePoint Management Shell**.
  On Subscription Edition the `SharePointServer` module is on `PSModulePath` and loads on demand, so
  the cache cmdlets resolve in a plain elevated `powershell.exe`. See fix #7 in §3.

---

## 3. What changed in v1.7

All six changes below are **written and verified off-farm only**. None has run against a real
SharePoint server. The whole batch is pinned to version 1.7 — append to the 1.7 block in the script
header rather than bumping to 1.8 for each subsequent fix in this batch.

| # | Change | Why |
|---|--------|-----|
| 1 | `Format-Duration` helper, used at all 3 timing call sites | `TimeSpan.Minutes` is only the minutes *component*, so it wrapped at 60. A 1h install reported "0 Minutes, 0 Seconds"; 3h05 reported "5 Minutes". |
| 2 | `Exit $installExitCode` at end; bare `Exit` on bad path → `Exit 1` | Script previously always exited 0, so automation could not detect a failed patch. |
| 3 | Table-driven service list (`$ServiceDefinitions`) + helper functions | Replaced 7 near-identical blocks × 4 places. Makes the asymmetric-restart bug structurally impossible. |
| 4 | Startup type set to `Disabled` for the duration of the install, then restored | Stops the installer *and* SCM recovery actions restarting a service mid-patch. Disable happens **before** the stop, closing the race where a recovery action revives it. |
| 5 | Only restart services that were running beforehand; restore each service's *original* startup type | Previously W3SVC/SPAdminV4/SPTraceV4/SPTimerV4 were started unconditionally, so the script could start services an admin had deliberately stopped. |
| 6 | `try`/`catch`/`finally` around the whole state-changing section | Without it, an abort left services stopped **and disabled** — worse than the pre-1.7 behaviour. Restore now runs on success, failure and exception alike. |
| 7 | Graceful DCache path rewritten onto the SharePoint cmdlets (was pending fix #2) | `Stop-SPDistributedCacheServiceInstance -Graceful` does the shutdown, which removed the hardcoded module import *and* the hardcoded port 22233. Prerequisites are now checked before anything is stopped, and the whole path runs in its own `try`. |
| 8 | Every wait is bounded — new `-ServiceTimeoutSeconds`, default 300 (was pending fix #4) | `WaitForStatus` had no timeout, so a wedged service hung the script forever. A hang can only be escaped by killing the process, which is the one case `finally` cannot recover from — so an unbounded wait was the most dangerous failure mode in the script. The graceful cache shutdown passes the same value to `-Timeout`. |
| 9 | A service that will not stop aborts the run; each service is restored in its own `try` | Patching while a service still holds its file locks defeats the entire purpose, so the run is abandoned and the startup types put back. Separately, one service failing to come back no longer abandons the restore of the others. |
| 10 | Unattended execution: `-Force`, `-ShouldGracefulStopDCache` as a switch, `[ValidateScript()]` on the path (was pending fix #6) | `Read-Host` blocked farm-wide automation. `-Force` skips it. The CU path is now rejected at bind time, so an unattended run fails immediately with exit 1 instead of starting and then stopping. **Breaking:** see below. |

### ⚠ Breaking change in 1.7

`-ShouldGracefulStopDCache` is now a `[switch]`, not a `[bool]`.

```powershell
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -ShouldGracefulStopDCache        # 1.7
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\cu.exe -ShouldGracefulStopDCache $true  # 1.6 and earlier
```

The old form **fails loudly rather than silently doing the wrong thing** — verified on `SPSE-DEV`:
PowerShell reads `$true` as a *positional* argument and the run aborts with `A positional parameter
cannot be found that accepts argument 'True'` and exit code 1. So a stale caller stops rather than
patching with the wrong cache behaviour, which is the failure mode that matters.

Anything scripted against the 1.6 signature still has to be updated. Stefan Goßner's blog post uses
the old form, so anyone following it will hit this. It is the one change in 1.7 that is not
backwards compatible.

### Design decisions worth preserving

- **Restore original startup type, not blanket `Automatic`.** A service that was `Manual` goes back to
  `Manual`. Startup type is read via `Get-CimInstance Win32_Service` rather than
  `ServiceController.StartType`, because only the former exposes `DelayedAutoStart`. `Set-Service`
  cannot express "Automatic (Delayed Start)", so that flag is restored by writing
  `HKLM:\SYSTEM\CurrentControlSet\Services\<name>\DelayedAutostart`.
- **Restore only what we changed.** Each service carries a `StartModeChanged` flag. If the startup type
  cannot be determined, the script warns, leaves it alone, and still stops it — it can never disable
  something it doesn't know how to put back. The flag is cleared on restore so `Restore-ServiceState`
  is idempotent.
- **SPCache is the one exception to disable-then-stop.** The graceful path runs
  `Stop-SPDistributedCacheServiceInstance -Graceful` / `Remove-SPDistributedCacheServiceInstance`
  *before* disabling, because unprovisioning a service instance that is already disabled fails.
- **SharePoint cmdlets only, never the AppFabric ones.** AppFabric is built into Subscription Edition.
  The SP\* cache cmdlets all come from the `SharePointServer` module, which is on `PSModulePath` and
  loads on demand — so the script imports nothing, needs no `Add-PSSnapin`, and is not tied to the
  SharePoint Management Shell. Verified on `SPSE-DEV`: importing `SharePointServer` does *not* provide
  `Stop-AFCacheHost`, which is why reaching for the AppFabric module was the wrong direction.
- **Timeouts walk the exception chain rather than relying on a typed `catch`.** PowerShell wraps an
  exception thrown out of a method call in a `MethodInvocationException`, and `catch [Type]` only
  unwraps **one** level. Verified on `SPSE-DEV`: a real `ServiceController` timeout arrives as
  `MethodInvocationException → TimeoutException` (typed catch matches), but one more call layer makes
  it `MethodInvocationException → RuntimeException → TimeoutException` (typed catch does **not**
  match). `Wait-ForServiceStatus` therefore walks `InnerException` and rethrows anything that is not a
  timeout, so a permissions failure can never be silently reported as a timeout.
- **A stop timeout aborts; a start timeout does not.** If a service will not stop, the patch must not
  proceed — the file locks are still held. If a service will not start afterwards, the patch is already
  applied, so it is reported and the remaining services are still restored.
- **The graceful path verifies its prerequisites before stopping anything.**
  `Add-SPDistributedCacheServiceInstance` is checked too, even though it is only used afterwards — the
  instance must never be unprovisioned unless it can be provisioned again. Any missing cmdlet falls
  back to a plain service stop instead of aborting the patch.
- **If the installer is still running when `finally` executes**, startup types are restored but services
  are **not** started — starting them mid-patch would restore the file locks. The operator is told to
  start them manually. Restoring a stopped service's startup type does not start it, so that half is
  always safe.
- **Exit code 17022 is propagated as-is**, not flattened to 0, so callers can distinguish "installed,
  needs reboot" from "installed clean".

---

## 4. Testing already done (off-farm, everything stubbed)

The harness is committed under `tests/` and targets Windows PowerShell 5.1 on the server — re-run it
after any change to the script. See `tests/README.md`.

```powershell
.\tests\Test-Logic.ps1
.\tests\Test-Integration.ps1
```

**Status: all 97 assertions pass (41 logic + 56 integration), both suites exiting 0.** Last run
2026-08-02 on `SPSE-DEV` under Windows PowerShell 5.1.20348.5386 — the real target engine on a real
SharePoint server, rather than the macOS environment the harness was originally written on.

It touches no real service and executes no installer; every service cmdlet is stubbed and the one
`Process::Start` call is replaced with a fake. Scratch files go to `%TEMP%\spse-cu-tests`.

- **Syntax**: `[Parser]::ParseFile` — clean.
- **41 unit assertions**: functions extracted from the real file via the AST (not copies) and run
  against stubbed cmdlets. Covered `Auto`→`Automatic` mapping, delayed-start set *and* clear, Manual
  passthrough, boot/system drivers left untouched, missing service → `$null`, stop/restart ordering,
  and that `Stop-DistributedCacheGracefully` returns a clean boolean rather than a pipeline polluted
  with cmdlet output. Fix #7 added five more: the prerequisite check passing and failing, and three
  AST assertions that no `*-AF*` cmdlet is invoked, that `Stop-SPDistributedCacheServiceInstance` is,
  and that the script imports no module. The negative prerequisite case passes an explicit cmdlet list
  rather than deleting a stub, because on a real SharePoint server `Get-Command` finds the genuine
  cmdlets regardless of the stubs. Fix #8 added six more covering the bounded waits: a timeout returns
  `$false`, a non-timeout error is rethrown rather than swallowed, the timeout reaches `WaitForStatus`
  as a `TimeSpan`, a service that will not stop is reported as a failure, one that was not running is
  left alone, and an AST assertion that no unbounded `WaitForStatus` call can be reintroduced.
- **56 integration assertions**: the *real script* run end-to-end in a child process, with only three
  edits (drop `#Requires`, inject stubs after `param()`, swap the single `Process::Start` for a fake).
  Eight scenarios — clean install, installer failure (17302), launch failure, abort mid-install, a
  service which will not stop (`$env:HANG_SERVICE` makes one service's wait time out; asserts the
  installer is never launched and every startup type is still restored), an unattended `-Force` run
  which asserts the prompt is never reached, the graceful cache path, and its fallback when the
  graceful stop throws. The last two also prove the `[switch]` binds and that the fallback
  reassignment of `$ShouldGracefulStopDCache` works.
- **The cache cmdlets are now stubbed in `Stubs.ps1`.** They were not before, which did not matter
  while no scenario reached the graceful path — but on a real SharePoint server the genuine cmdlets
  resolve, so exercising that path unstubbed would have acted on the live farm.
  Verified disable-before-stop ordering, reverse restart order, delayed-start preservation, that a
  stopped/Manual service is disabled but never started, that an already-Disabled service is untouched,
  that an uninstalled service is skipped silently, and that startup types are restored in every
  failure path.

### Known gaps in that testing

- **A real Ctrl-C was never verified.** A SIGINT sent to a backgrounded `pwsh` on macOS did **not** run
  the `finally`. Windows Ctrl-C uses a console control handler — a different mechanism where PowerShell
  normally does run `finally` — so this is not evidence against the design, but it is unproven. All
  verified aborts were exception-based.
- A forced process kill (Task Manager, `taskkill`, closing the console window) genuinely cannot be
  intercepted and **will** leave services stopped and disabled. Recovery notes are in the script header.
- Never exercised at all: `Set-Service`, the registry write, every SharePoint cache cmdlet, and the
  actual patch installation.

---

## 5. Testing that remains — must happen on the server

Take a snapshot before and after and compare; this is the primary assertion.

```powershell
"SPTimerV4","SPTraceV4","SPAdminV4","W3SVC","OSearch16","SPSearchHostController","SPCache" |
    ForEach-Object { Get-CimInstance Win32_Service -Filter "Name='$_'" -ErrorAction SilentlyContinue } |
    Select-Object Name, State, StartMode, DelayedAutoStart | Format-Table -AutoSize
```

Always capture a transcript — the console output records each service's original startup type and is
the recovery data if a run is interrupted:

```powershell
Start-Transcript -Path C:\temp\spse-cu.log
.\Install-SPSE_Fix.ps1 -CULocation C:\temp\uber-subscription-kbXXXXXXX-fullfile-x64-glb.exe
Stop-Transcript
```

Checklist:

1. **Dry run (safe).** Nothing is modified before the `PRESS ENTER TO CONTINUE` prompt — the plan is
   printed, including each service's current startup type, *before* the `try` block. Run it, read the
   plan, Ctrl-C at the prompt. Confirm the printed plan matches the snapshot command above.
2. **Full run, `-ShouldGracefulStopDCache` omitted.** This isolates the new logic from the untested
   DCache path. Confirm the after-snapshot is byte-for-byte identical to the before-snapshot.
3. **Delayed start.** If any service is "Automatic (Delayed Start)", confirm `DelayedAutoStart` is
   still `True` afterwards. If none is, set one deliberately first — this is the highest-risk untested
   code path, since a wrong restore silently changes farm boot behaviour.
4. **Exit code.** `$LASTEXITCODE` after the run. Expect 0, or 17022 if a reboot is required.
5. **A service that was stopped beforehand stays stopped**, and its startup type is unchanged. Stop one
   (e.g. `OSearch16` on a role that doesn't need it) before running.
6. **A service not installed on this role is skipped silently** — no red errors. A WFE without Search
   is a good test.
7. **Interrupt test on a throwaway box**: Ctrl-C during the install and confirm `finally` restores the
   startup types. This is the gap from §4 and is worth doing deliberately.
8. **Graceful DCache path** (`-ShouldGracefulStopDCache`) — the control flow is now covered off-farm
   (both the success path and the fallback), but every cmdlet in it is stubbed, so nothing has run
   against a real cache cluster. Run it on a server that hosts distributed cache, from a plain
   elevated `powershell.exe` (**not** the Management Shell — that is the point of fix #7), and
   confirm `Get-SPCacheClusterHealth` reports the host back in the cluster afterwards.
9. Reboot-required (17022) and >1 hour duration formatting are impractical to force; both are covered
   by the off-farm tests.
10. **The 300 second default for `-ServiceTimeoutSeconds` is an estimate, not a measurement.** Time how
    long `OSearch16` and `SPTimerV4` really take to stop on this farm — Search in particular can be
    slow. If either is anywhere near 300s, raise the default: setting it too low converts a slow but
    healthy service into an aborted patch run, which is a worse outcome than waiting.

---

## 6. Pending fixes

**None. All of #2, #4, #6 and #8 are done** — see the change table in §3.

Fix #8 produced `README.md`, which is where this document's durable content now lives: purpose, the
blog rationale, requirements, usage, the full parameter and exit code tables, what the script does to
the services, forced-termination recovery, and the 1.7 breaking change.

Also noted but not scheduled: no `Set-StrictMode`, no `$ErrorActionPreference`, and no
logging/transcript built in (the README tells operators to wrap runs in `Start-Transcript`, which
covers the operational need without changing the script).

The `$PWD` footgun previously listed here is fixed: relative paths now resolve against
`Get-Location -PSProvider FileSystem`, so a current location on another provider such as `HKLM:\` no
longer produces a nonsense path.

---

## 7. Repo state

- `.DS_Store` is covered by a **global** gitignore on the original machine, not a repo-level one. There
  is no `.gitignore` in this repo — worth adding if the server sees stray files.
- The off-farm test harness is in `tests/` (`Test-Logic.ps1`, `Test-Integration.ps1`, `Stubs.ps1`).
  It targets Windows PowerShell 5.1 and is Windows-only by design: `Test-Integration.ps1` spawns
  `powershell.exe` per scenario.
- **The harness now passes on Windows** (2026-08-02, `SPSE-DEV`, Windows PowerShell 5.1.20348.5386) —
  97/97, first run on the platform. It had only ever been run on macOS while it was still
  cross-platform, and the three Windows-specific pieces added when it was simplified to Windows-only
  (`powershell.exe` as the child shell, `-ExecutionPolicy Bypass`, and asserting the un-masked exit
  code 17302) were unproven until this run. All three work.
  If a future run fails, note that `Test-Logic.ps1` has no Windows-specific parts: if that one passes
  and `Test-Integration.ps1` does not, suspect the harness plumbing before the script under test.
- Suggested commit convention for this batch: keep everything under version 1.7 and append to the 1.7
  block in the script header.
- `README.md` (fix #8) and `CLAUDE.md` are new and **untracked** — neither is committed yet, and nor is
  anything else in this batch.
- `upstream` is **not configured on this machine**; only `origin` exists. The fork relationship is
  recorded in §1 and in the README, but not in git config here. Add it if you want to diff against
  Stefan Goßner's original:
  `git remote add upstream https://github.com/stefangossner/Install-SPSE_Fix.git`

---

## 8. Retiring this document

This file is temporary. It can be deleted once the handover is complete. State as of 2026-08-02:

| Section | Where it lives permanently | Done? |
|---|---|---|
| §1 purpose, blog rationale, fork | `README.md` | ✅ |
| §2 environment / requirements | `README.md` | ✅ |
| §3 design decisions and invariants | `CLAUDE.md`, plus the script's own comments | ✅ |
| §3 v1.7 change list, breaking change | `README.md` | ✅ |
| §4 what the tests cover and their limits | `tests/README.md` | ✅ |
| §6 pending fixes | nothing left to carry | ✅ |
| **§5 on-server test checklist** | **nowhere — not yet executed** | ❌ |

**§5 is the only thing still holding this file open.** It is blocked on a CU package: as of
2026-08-02 there is none on `SPSE-DEV`, and items 2–7 all need one. Everything verified so far is
stubbed logic — no part of this script has run against a real patch, a real service, or a real cache
cluster.

Either work through §5 and delete this file, or move the checklist into `tests/README.md` as the
on-server procedure and delete the rest.
