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
throwing. See `HANDOFF.md` for the on-server test checklist that covers the rest.
