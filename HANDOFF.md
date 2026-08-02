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
- If testing the `-ShouldGracefulStopDCache $true` path, use the **SharePoint Management Shell** — see
  pending fix #2, the script does not load the `Microsoft.SharePoint.PowerShell` snap-in itself.

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
- **SPCache is the one exception to disable-then-stop.** The graceful path runs `Stop-AFCacheHost` /
  `Remove-SPDistributedCacheServiceInstance` *before* disabling, because unprovisioning a service
  instance that is already disabled fails.
- **If the installer is still running when `finally` executes**, startup types are restored but services
  are **not** started — starting them mid-patch would restore the file locks. The operator is told to
  start them manually. Restoring a stopped service's startup type does not start it, so that half is
  always safe.
- **Exit code 17022 is propagated as-is**, not flattened to 0, so callers can distinguish "installed,
  needs reboot" from "installed clean".

---

## 4. Testing already done (off-farm, macOS, everything stubbed)

The harness is committed under `tests/` and targets Windows PowerShell 5.1 on the server — re-run it
after any change to the script. See `tests/README.md`.

```powershell
.\tests\Test-Logic.ps1
.\tests\Test-Integration.ps1
```

It touches no real service and executes no installer; every service cmdlet is stubbed and the one
`Process::Start` call is replaced with a fake. Scratch files go to `%TEMP%\spse-cu-tests`.

- **Syntax**: `[Parser]::ParseFile` — clean.
- **19 unit assertions**: functions extracted from the real file via the AST (not copies) and run
  against stubbed cmdlets. Covered `Auto`→`Automatic` mapping, delayed-start set *and* clear, Manual
  passthrough, boot/system drivers left untouched, missing service → `$null`, stop/restart ordering,
  and that `Stop-DistributedCacheGracefully` returns a clean boolean rather than a pipeline polluted
  with cmdlet output.
- **27 integration assertions**: the *real script* run end-to-end in a child process, with only three
  edits (drop `#Requires`, inject stubs after `param()`, swap the single `Process::Start` for a fake).
  Four scenarios — clean install, installer failure (17302), launch failure, abort mid-install.
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
- Never exercised at all: `Set-Service`, the registry write, every AppFabric/SharePoint cmdlet, and the
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
8. **Graceful DCache path** — blocked on pending fix #2 below.
9. Reboot-required (17022) and >1 hour duration formatting are impractical to force; both are covered
   by the off-farm tests.

---

## 6. Pending fixes

| # | Fix | Detail |
|---|-----|--------|
| 2 | **DCache module import order + missing snap-in** | `Use-SPCacheCluster` is called one line *before* the `DistributedCacheAdministration` module that provides it is imported. `Add`/`Remove-SPDistributedCacheServiceInstance` need the `Microsoft.SharePoint.PowerShell` snap-in, which the script never loads — so the graceful path only works from the SharePoint Management Shell. Module path and `CachePort 22233` are hardcoded. **Deliberately carried over verbatim from 1.6** so an untestable behaviour change didn't ride along with the refactor; the code is marked with a `NOTE:` comment. |
| 4 | **`WaitForStatus` timeouts** | Every call has no timeout, so a wedged SPTimerV4 or OSearch16 hangs the script indefinitely. Use the `[TimeSpan]` overload and handle `System.ServiceProcess.TimeoutException`. |
| 6 | **Unattended execution** | `Read-Host "PRESS ENTER TO CONTINUE"` blocks farm-wide automation — add `-Force`/`-NonInteractive`. Change `[bool]$ShouldGracefulStopDCache` to `[switch]` (currently requires the unidiomatic `-ShouldGracefulStopDCache $true`). Move path validation into `[ValidateScript()]`. |
| 8 | **README** | Repo has none. Document purpose, the blog rationale, usage, and the exit codes v1.7 now returns. |

Also noted but not scheduled: no `Set-StrictMode`, no `$ErrorActionPreference`, no logging/transcript
built in, and `$PWD` is combined via `[IO.Path]::Combine` which misbehaves if the current location is a
non-FileSystem provider (e.g. `HKLM:\`).

---

## 7. Repo state

- `.DS_Store` is covered by a **global** gitignore on the original machine, not a repo-level one. There
  is no `.gitignore` in this repo — worth adding if the server sees stray files.
- The off-farm test harness is in `tests/` (`Test-Logic.ps1`, `Test-Integration.ps1`, `Stubs.ps1`).
  It targets Windows PowerShell 5.1 and is Windows-only by design: `Test-Integration.ps1` spawns
  `powershell.exe` per scenario.
- **The harness has never been run on Windows.** All 46 assertions passed on macOS while it was still
  cross-platform; it was then simplified to Windows-only, and the three Windows-specific pieces
  (`powershell.exe` as the child shell, `-ExecutionPolicy Bypass`, and asserting the un-masked exit
  code 17302) are written but unproven. If the first run on the server fails, suspect the harness
  before the script under test — and note `Test-Logic.ps1` has no Windows-specific parts, so if that
  one passes and `Test-Integration.ps1` does not, the fault is almost certainly in the harness plumbing.
- Suggested commit convention for this batch: keep everything under version 1.7 and append to the 1.7
  block in the script header.
