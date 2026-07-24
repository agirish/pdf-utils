# CI

`.github/workflows/tests.yml` runs the `PdfToolkit` package test suite on every
push to `main`, on a self-hosted runner (GitHub-hosted macOS minutes bill at 10x
on a private repo, and the hosted toolchain lags the one this repo is developed
against).

## Scope

- One package: `Packages/PdfToolkit` (720 tests across 74 suites as of this
  writing) — the app's only test target. `swift test --package-path
  Packages/PdfToolkit`.
- The **real-PDF corpus** (`docs/testing-corpus.md`) ships as a committed test
  resource, so `RealCorpusTests` runs in CI like everything else — no Chrome, no
  network, no generation step. A `Check the real-PDF corpus is present` step runs
  before the suite so a file missing from the bundle names itself instead of
  surfacing as an opaque `fatalError` inside the runner.
- **No app-target step** (unlike SyncCloud's CI). The root `Package.swift` — the
  `PdfUtils` app plus the `PdfUtilsFinder` extension and `PdfUtilsHelper`
  executables — has no test target, and the app can't be built with
  xcodegen/xcodebuild here: `AppDelegate` uses `Bundle.module`, which only exists
  under SwiftPM (an xcodegen project fails to compile, "type 'Bundle' has no
  member 'module'"). All logic under test is factored into `PdfToolkit`, so the
  package suite is the whole verification surface.
- No machine-pinned image-snapshot tests, so nothing is skipped (contrast
  SyncCloud, which excludes `*SnapshotTests`).

## Per-commit verdicts

`concurrency.cancel-in-progress` is **false**: every push gets its own run
instead of newer pushes cancelling older ones. On the single self-hosted runner
the runs serialize, so a burst of close landings each land a green/red verdict
and a break is bisectable to the exact SHA — which matters because commits here
get audited. A run is ~2-3 min on our own hardware, so the cost is negligible;
if a long burst ever backs the queue up, cancel stale runs with `gh run cancel
<id>`.

## Runner

Registered as `pdfutils-mac` (labels `self-hosted`, `macOS`, `X64`), installed at
`~/actions-runner-pdfutils-x64`, running as a LaunchAgent
(`actions.runner.agirish-pdf-utils.pdfutils-mac`). This is a **separate** runner
instance from SyncCloud's — self-hosted runners on a personal account are
registered per-repository, so `agirish/pdf-utils` needs its own. Re-register
after a machine move (a fresh token can be minted with `gh` — see below):

```sh
cd ~/actions-runner-pdfutils-x64
TOKEN=$(gh api -X POST repos/agirish/pdf-utils/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/agirish/pdf-utils --token "$TOKEN" --name pdfutils-mac --work _work --unattended
./svc.sh install && ./svc.sh start
```

### Known issue: fork deadlock on macOS 26 (Tahoe) — why the runner is x86_64

macOS 26 has a fork regression: children forked from a multithreaded process can
wedge pre-exec, spinning one thread at 100% CPU (observed with the runner's .NET
host; also reported against Ruby on 26.1). Symptom: a job step "runs" forever,
`ps` shows a second `Runner.Worker spawnclient` process in state `R` at 100% CPU
with a tiny footprint, and killing it only makes the worker fork another.

Mitigation (proven on this machine during the SyncCloud CI bring-up): the agent
runs as the **osx-x64 build under Rosetta** (`~/actions-runner-pdfutils-x64`,
seeded by copying SyncCloud's already-vetted x64 runner payload and registering
fresh), which takes a different fork path through the translation layer. If a run
wedges anyway: kill the `Runner.Worker` processes, restart the runner, re-run the
workflow. Track the OS bug before blaming test code — every wedge so far happened
in the runner agent, never in `swift test`.

### Rosetta corollary: `swift test` exit code lies under x86_64

Under the x64 agent, `swift test` inherits x86_64 and then **exits 1 with every
test passing** (isolated by A/B during SyncCloud bring-up: same workspace +
native arm64 -> 0; x86_64 -> 1; env and cwd innocent). The workflow therefore
runs the payload as `arch -arm64 swift test …`. When checking test outcomes by
hand, never judge from piped output (`… | tail`) — the pipe masks the real exit
code.

## Checking results

`gh` is authenticated (account `agirish`). After any push to `main`:

```sh
gh run list --repo agirish/pdf-utils --limit 5     # newest run's headSha should match your commit
gh run view <id> --log-failed                       # failing test / expectation on a red run
```

A missing run for a pushed SHA is not a pass — it usually means the runner isn't
listening (`gh api repos/agirish/pdf-utils/actions/runners` to check); see the
recovery recipe above.
