# Off-farm tests for Install-SPSE_Fix.ps1

These verify the script's logic without a SharePoint farm, a CU package, or any change to the
machine. Run them after editing `Install-SPSE_Fix.ps1`.

```powershell
.\tests\Test-Logic.ps1
.\tests\Test-Integration.ps1
```

Each exits with the number of failed assertions, so `$LASTEXITCODE -eq 0` means everything passed.

These target **Windows PowerShell 5.1 on the SharePoint server** — the engine the SharePoint
Management Shell uses and the one `Install-SPSE_Fix.ps1` is written for. `Test-Integration.ps1`
spawns `powershell.exe` for each scenario, so it is Windows-only by design.

## Safety

**Neither script touches a real service and neither executes an installer.** `Get-Service`,
`Set-Service`, `Get-CimInstance` and `Set-ItemProperty` are all replaced by stub functions (a
function takes precedence over a cmdlet of the same name), and the one
`[Diagnostics.Process]::Start` call is textually replaced with a fake before the copy is run. The
integration harness aborts if that substitution fails to match, so it cannot silently fall through
to launching something real.

The SharePoint distributed cache cmdlets are stubbed for the same reason. These tests are meant to run
on the SharePoint server itself, where `Use-SPCacheCluster`,
`Stop-SPDistributedCacheServiceInstance` and the rest all resolve for real — so the graceful cache
scenarios would otherwise act on the live farm.

Scratch files are written to `%TEMP%\spse-cu-tests`, not into the repo.

## What each covers

**`Test-Logic.ps1`** — extracts the helper functions from the real script via the AST and
dot-sources them, so it tests the shipped code rather than a copy. Covers the `Auto`→`Automatic`
mapping, the delayed-auto-start flag being both set and cleared, `Manual` passthrough, boot/system
drivers being left alone, a service that is not installed returning `$null`, stop/restart ordering,
and that `Stop-DistributedCacheGracefully` returns a clean boolean rather than a pipeline polluted
with cmdlet output. It also checks the distributed cache prerequisites — that
`Test-DistributedCacheSupport` passes when every cmdlet is present and fails when one is not, and,
via the AST, that the script invokes no `*-AF*` AppFabric cmdlet, does use
`Stop-SPDistributedCacheServiceInstance`, and imports no module.

The missing-cmdlet case passes an explicit cmdlet list instead of removing a stub: these tests run on
a real SharePoint server, where `Get-Command` resolves the genuine cache cmdlets no matter what the
stubs define.

It also covers the bounded waits — that a timeout returns `$false` while any other error is rethrown
rather than swallowed, that the timeout reaches `WaitForStatus` as a `TimeSpan`, that a service which
will not stop is reported as a failure, and, via the AST, that no unbounded `WaitForStatus` call can
be reintroduced.

**`Test-Integration.ps1`** — runs the whole script end to end in a child process against a
deliberately mixed fake farm (running Automatic services, one delayed-start service, a stopped
Manual service, an already-Disabled service, and one service not installed at all). Eight scenarios:
clean install, installer failure, launch failure, abort mid-install, a service which will not stop, an
unattended `-Force` run, the graceful distributed cache path, and that path falling back when the
graceful stop throws. Asserts disable-before-stop ordering, reverse restart order, delayed-start
preservation, that a stopped service is never started, that an already-Disabled service is untouched,
that a missing service is skipped silently, that the CU path is rejected at bind time with exit 1, and
that startup types are restored down every failure path.

Two environment variables drive the awkward scenarios: `$env:HANG_SERVICE` names a service whose
`WaitForStatus` times out, and `$env:DCACHE_RUNNING` makes `SPCache` a running cache host so the
graceful path engages.

## Limits

These cannot exercise `Set-Service`, the registry write, the SharePoint cache cmdlets, or a real
patch installation — all are stubbed. A real Ctrl-C is also not covered: aborts are simulated by
throwing.

## Verified on a real farm

The script was run against a real CU on 2026-08-02: `SPSE-DEV`, July 2026 CU (KB5002882), taking
build 16.0.19725.20280 → 16.0.19725.20434. Exit code **0**, and the service state afterwards was
**identical to before across all seven services** — including `OSearch16` returning to `Manual`
rather than being started as `Automatic`. The install took 8m51s. `Microsoft.SharePoint.dll` was
confirmed at the new version, and PSConfig afterwards took `BuildVersion` to 16.0.19725.20434 with
`NeedsUpgrade` false.

Mid-run, all seven services were observed `Stopped` **and** `Disabled` simultaneously. That is the
disable-before-stop ordering doing its job: 40 minutes earlier on the same box, `OSearch16` had been
restarted by `SPSearchHostController` 8 seconds after a manual stop, and under the script it stayed
down.

### Still never tested anywhere

- **A stopped service staying stopped, on a real farm.** It cannot be staged: SharePoint restarts its
  own services within seconds (`SPSearchHostController` → `OSearch16` is the clearest case). Covered
  off-farm only, where the fake farm stages a stopped `Manual` service directly.
- **A service not installed on the server.** Needs a role that lacks one — a WFE without Search. The
  test farm is single-server, so all seven services exist.
- **The graceful distributed cache path against a real cache cluster.** The control flow is covered
  off-farm, both the success path and the fallback, but every cmdlet in it is stubbed. Note that a
  single-server farm is a degenerate test anyway: with one cache host there is no peer to hand the
  cached data to.
- **A real Ctrl-C**, and therefore whether `finally` runs on a Windows console control event. Every
  abort tested so far is exception-based.
- **Exit code 17022, and durations over an hour.** Impractical to force; covered off-farm.
- **The 300s default timeout at its limit.** Nothing came close on a real run, so the default is
  untested rather than proven. Time `OSearch16` and `SPTimerV4` on a busy production farm before
  trusting it — too low turns a slow but healthy service into an aborted patch run.

### About the test farm

`SPSE-DEV` is a single-server farm with **local SQL**, which is why a VM snapshot is a complete
rollback there — it captures the binaries and the databases together. On a farm with remote SQL, a
snapshot of the SharePoint VM alone would not roll back the schema changes a CU makes. Do not assume
the rollback story transfers.

Two behaviours worth knowing before designing further on-farm tests:

- SharePoint services are never "Automatic (Delayed Start)" — they are `Automatic` or `Manual`
  according to the server role. `W3SVC` is the only service in the script's list that is IIS rather
  than SharePoint, so it is the only realistic subject for that code path. Even then, PSConfig clears
  the flag during an upgrade.
- SharePoint actively restores its own services to the running state, which is why the script sets
  startup type to `Disabled` *before* stopping anything. Never reorder that.
