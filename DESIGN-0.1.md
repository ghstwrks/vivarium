# Vivarium v0.1 — design

Vivarium runs user-defined tests autonomously inside a macOS virtual machine,
against user-defined code. The host orchestrates everything: guest
preparation, test execution, artifact harvesting, and report creation. No
human touches the guest.

This document is the working spec for the pivot from the proof of concept
(`vre-poc`, see `POC-RESULTS.md`) to Vivarium v0.1. The POC's findings are
load-bearing; nothing here contradicts them without saying so.

## Name

**Vivarium**, binary **`viv`**. A vivarium is a sealed, controlled enclosure
in which something is kept alive so its behaviour can be observed — which is
precisely what this tool does with a macOS guest. The POC name (VREPOC,
"Virtualization Reverse Engineering Proof of Concept") encoded an assumption
that turned out to be wrong; the RE never happened because the public API
sufficed.

## What v0.1 is

A single, delightful path:

```sh
viv template create --ipsw ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw
cd ~/my-project
viv run -- swift test
```

`viv run` clones the template, provisions a fresh guest (per-run credentials,
no Setup Assistant), copies the user's code in, runs their test command,
streams its output live to the host terminal, harvests artifacts, writes a
report, shuts the guest down, and deletes the expensive VM.bundle — keeping
only the results.

## Command surface

```
viv preflight [--ipsw <path>]        Host, entitlement, disk, image checks. Creates nothing.
viv template create --ipsw <path>    Restore macOS into a template bundle (was: install).
viv template list                    List templates with build, size, created date.
viv run [options] [-- <command…>]    The core pipeline. See below.
viv selftest [options]               The POC acceptance proof (13 criteria + negative
                                     tests), preserved as Vivarium's own integration test.
viv validate --bundle <path>         Re-check an existing bundle's artifact disk. (POC carry-over.)
viv gc [--dry-run] [--all | --older-than <days>]
                                     Delete run directories under the Vivarium home.
```

All flags accept both `--flag value` and `--flag=value` — this comes free
from swift-argument-parser, whose adoption is part of this pivot. The POC's
hand-rolled parser (which rejected `=`) is retired; the zero-dependency
rationale died with the POC.

## `viv run` — the core pipeline

### Inputs

- `--code <dir>` — the user's project directory. Default: the current
  directory.
- `-- <command…>` — the test command, run in the guest copy of the code
  directory. Overrides the manifest.
- `--manifest <path>` — defaults to `<code>/viv.json` if present.
- `--template <path>` — defaults to the newest template in the Vivarium home.
- `--timeout <seconds>` — test command budget. Default 600. Per the POC's
  hard-won rule: bound *each* attempt, not just an outer loop.
- `--keep-vm` — keep the VM.bundle even on success.
- Carry-overs where they still make sense: `--guest-address`, `--username`,
  `--no-auto-login`, `--skip-ipsw-digest`, etc.

### Manifest (`viv.json`)

JSON because Codable parses it with no new dependency:

```json
{
  "name": "my-project",
  "test": "sh run-tests.sh",
  "artifacts": ["logs/**", "results.xml"],
  "timeout": 600,
  "env": { "CI": "1" }
}
```

Everything is optional. CLI flags and the trailing `-- <command>` override the
manifest. If neither a manifest `test` nor a trailing command exists, `viv
run` errors with a message that shows both ways to provide one.

### Pipeline

1. **Resolve** template, code dir, manifest, command. Fail fast with
   actionable messages (e.g. no template → print the `viv template create`
   line to run).
2. **Materialise** the run: `~/.vivarium/runs/<run-id>/` with `VM.bundle`
   cloned from the template (`clonefile`, ~0.03 s per the POC), `Shared/`
   VirtioFS directory, `results/`.
3. **Stage code**: copy the user's code directory into `Shared/code/`
   (APFS clone; cheap). The user's original directory is never mounted
   directly and never written to.
4. **Provision & boot** the guest exactly as the POC does (per-run password,
   in-memory only; DHCP-lease-first address discovery; SSH readiness gates).
5. **Execute**: over SSH, copy `code/` from the share to a guest-local
   workdir (avoids VirtioFS build/exec quirks), then run the test command
   there with the manifest env plus `VIV_RUN_ID`, `VIV_ARTIFACTS` (guest path
   whose contents are harvested). Stream stdout/stderr live to the host
   terminal, prefixed distinctly, while also capturing them separately.
6. **Harvest**: copy manifest `artifacts` globs (relative to the guest
   workdir) and everything under `VIV_ARTIFACTS` back via the share into
   `results/artifacts/`; write `results/test-stdout.txt`,
   `test-stderr.txt`.
7. **Report**: `results/report.json` (run metadata, timings per phase, test
   exit code, artifact inventory, pass/fail) and a human-readable terminal
   summary. `results/report.md` mirrors the summary.
8. **Shutdown** via the proven path: `requestStop()` with a short budget,
   then in-guest `sudo shutdown -h now` (the one that actually works — see
   POC-RESULTS.md).
9. **Clean up**: on success, delete `VM.bundle` (and the staged
   `Shared/code`), keeping `results/`. On failure, keep everything and say
   so: `run kept for inspection: viv gc cleans it later`. `--keep-vm`
   forces keeping.

### Exit codes

- `0` — infrastructure succeeded and the test command exited 0.
- `1` — infrastructure succeeded; the test command failed. The user's tests
  failing is not Vivarium failing.
- `2` — usage error.
- `70` — Vivarium/infrastructure failure (EX_SOFTWARE).

## Home directory

`~/.vivarium/` (override: `VIVARIUM_HOME`), following the `~/.tart`
precedent:

```
~/.vivarium/
  templates/<build>.bundle
  runs/<run-id>/
    VM.bundle/        deleted on success
    Shared/           staged code + harvest channel; code deleted on success
    results/          always kept: report.json, report.md, streams, artifacts/
```

The POC's `~/VRE-POC` is **never touched** by Vivarium — not by `viv run`,
not by `viv gc`. Existing templates can be adopted by copying (APFS clone)
into `~/.vivarium/templates/`; the README documents the one-liner.

`viv gc` only ever deletes under `~/.vivarium/runs/`, uses
`FileManager.removeItem` (no Trash, so no `.Trashes` residue), clears
read-only bits first if removal fails, supports `--dry-run`, and prints what
it deleted and how much space returned.

## Renames

| POC | Vivarium |
|---|---|
| package/product `vre-poc` | `vivarium` / `viv` |
| target/module `VREPOC` | `Vivarium` |
| `VREPOC.entitlements` | `Vivarium.entitlements` |
| `POCOrchestrator` | `Orchestrator` |
| `POCError` | `VivError` |
| `VRE_DEBUG` | `VIV_DEBUG` |
| default account `vreadmin` | `vivadmin` |
| artifact volume `VREArtifacts` | `VivArtifacts` |
| `~/VRE-POC` | `~/.vivarium` |

`VZMacGuestProvisioning-POC-Plan.md` and `POC-RESULTS.md` are historical
documents and are not edited (the plan explicitly so).

## Out of scope for v0.1

Concurrent runs (POC future-work #6), SSH-key provisioning (#3), dropping
auto-login (#1), remote IPSW download, non-macOS guests, config beyond the
manifest. Each is a natural v0.2 candidate.
