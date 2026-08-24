# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet follow Semantic Versioning strictly — see
`DESIGN-0.1.md` for what v0.1 deliberately leaves out.

## [Unreleased]

### Added

- A per-state timing breakdown in `results/report.json`, `results/failure.json`,
  and `viv selftest`'s report: a `states` array giving every state the run
  entered, when it entered it (as an offset from the start of the run and as a
  wall-clock date), and how long it stayed there. The pipeline's coarser
  `phases` are unchanged, and remain what `report.md` and the terminal summary
  show. The state transitions were already logged, and already written to
  `logs/state.jsonl` — but that file lives inside the `VM.bundle` a passing run
  deletes, so the timings for exactly the runs worth comparing did not survive.
  Now they are in the reports that are archived, where a boot or a staging step
  that has been getting slower can be found by comparing runs rather than by
  happening to watch one.

### Fixed

- `viv gc --all` now removes dangling symlinks under `runs/` as links. The
  safety model already refused to follow these entries, but the final removal
  used an existence check that follows symlinks and therefore treated a link to
  a missing target as if the link itself did not exist.
- Manifest validation now rejects NUL bytes in test commands, environment
  values, and artifact patterns, and rejects every Unicode line separator in
  artifact patterns. These values are passed through shell strings or a
  line-oriented here-document and cannot be represented faithfully otherwise.

### Changed

- Added focused unit tests for manifest/environment parsing and safe run-storage
  deletion.
- Aligned the README, generated CLI help, and Action documentation with actual
  behavior, including `--keep-vm` retaining both `VM.bundle` and `Shared/`, the
  fields that can override `viv.json`, and the measured versus maximum restore
  duration. Implementation comments now describe current invariants rather
  than past debugging history.

## [0.1.0] - 2026-08-10

### Pivot

Renamed the project from `vre-poc` to **Vivarium** (binary `viv`). The proof
of concept answered its question — `VZMacGuestProvisioningOptions` gets a
macOS 27 guest through first boot with no human at Setup Assistant, and the
host can independently prove what the guest did — so the tool built on top
of that answer is no longer a proof of concept, and its old name's "reverse
engineering" premise no longer applies. `POC-RESULTS.md` and
`VZMacGuestProvisioning-POC-Plan.md` are kept as historical records and are
not edited.

### Added

- A CLI built on `swift-argument-parser`, replacing the POC's hand-rolled
  parser (which rejected `--flag=value`). Every subcommand now takes both
  `--flag value` and `--flag=value`, gets generated `--help`, and reports
  usage errors with exit code 2.
- `viv run`, the core pipeline: clone a template, provision and boot a
  fresh guest, copy a project's code onto the guest, run its test command
  with output streamed live to the terminal while captured in full, harvest
  artifacts, write a report, shut the guest down, and delete the expensive
  parts of the run directory on success.
- The `viv.json` project manifest (`name`, `test`, `artifacts`, `timeout`,
  `env`), read strictly — an unrecognised key is a hard error rather than a
  silently ignored typo.
- Live-streamed guest output: the test command's stdout and stderr reach
  the host terminal as they are produced, not only after the command exits,
  and are written to `results/test-stdout.txt` and `results/test-stderr.txt`
  at the same time — so a run in progress can be followed with `tail -f`,
  and a run that dies mid-test still has everything printed up to then.
- An exit-code contract `viv run` keeps: `0` for a test command that
  exited 0, `1` for one that failed or timed out, `2` for a usage error,
  and `70` for every failure of Vivarium's own — a guest that never took a
  lease, a share that did not mount, an SSH session that would not open.
  Exit `1` means the tests failed and nothing else.
- `--keep-going`, which holds a failed run's guest at the point of failure
  and prints its address, so an operator can SSH in and look; Ctrl-C then
  force-stops the guest and exits with the status the run had earned.
- The test command runs as the shell script it is: `set -e` and `set -u`
  cover Vivarium's own preamble but are turned off for the user's command,
  which behaves as it would in their own shell.
- Artifact harvesting: manifest globs resolved by the guest's own shell,
  plus everything written to `$VIV_ARTIFACTS`, copied back through the
  VirtioFS share into `results/artifacts/`.
- `results/report.json` and `results/report.md`, recording run metadata,
  per-phase timings, the test command's exit status, the artifact
  inventory, and pass/fail — with optional fields omitted rather than
  written as `null` when they do not apply.
- Automatic cleanup: a passing run deletes its own `VM.bundle` and staged
  `Shared/` directory, keeping only `results/`; a failing or timed-out run
  keeps everything for inspection.
- `viv gc`, for cleaning up runs kept after a failure or timeout. By
  default it reclaims only the heavy remains — `VM.bundle` and `Shared/` —
  of runs that finished, and keeps every `results/`; `--older-than <days>`
  and `--all` delete whole run directories, `results/` included.
  `--dry-run` shows what any of them would do. Only `<home>/runs` is ever
  touched.
- `viv preflight`, `viv template create`/`viv template list`, `viv
  validate`, and `viv selftest` (the POC's thirteen-criterion acceptance
  proof, preserved as Vivarium's own integration test), each carried over
  from the proof of concept and renamed onto the new command surface.
- `--run-id`, which pins a run's identifier and therefore its directory.
  Without it a caller can only find the results by guessing which of the
  directories under `runs/` was theirs; with it, the place the results will
  be written is known before the run that writes them starts. Refuses an
  identifier that is empty, longer than 128 characters, starts with `.` or
  `-`, contains anything outside `[A-Za-z0-9._-]`, or names a run directory
  that already exists.
- `--env-file`, which reads `NAME=value` lines and adds them to the test
  command's environment, overriding the manifest's `env`. A file rather
  than a flag because a command line is readable by every process on the
  host, and this is where a CI secret belongs. Parsing is deliberately
  literal — not dotenv: everything after the first `=` is the value, quotes
  and `$` included, with nothing stripped, expanded, or unescaped. The name
  rules are the manifest's own, now shared by both through
  `GuestEnvironment`.
- **A GitHub Action** (`action.yml`), so a downstream project gets a
  clean-slate guest per job from a few lines of workflow. It runs the
  tests, writes the report to the job summary, uploads `results/` as a
  workflow artifact, reclaims disk with `viv gc`, and maps Vivarium's exit
  codes onto the step's success or failure — including the distinction that
  matters most in CI, that exit 70 fails the step regardless of
  `fail-on-test-failure`, because the tests never ran. Requires a
  self-hosted Apple silicon runner: GitHub's hosted macOS runners cannot
  nest virtualization. See `docs/github-actions.md`.
- **Signed, notarised release binaries**, published by
  `.github/workflows/release.yml` when a `v*` tag is pushed: a Developer ID
  signature with the hardened runtime, notarised by Apple, attached to the
  GitHub release with a `checksums.txt`. Signing is not decoration — an
  unsigned binary cannot hold `com.apple.security.virtualization`, and
  without that entitlement `viv` cannot create a guest at all.
- The Action **downloads that release** rather than compiling one, keyed to
  the ref the workflow pinned it to, so `@v0.1.0` gets v0.1.0's action
  definition and v0.1.0's binary and never a mixture. A runner therefore
  needs no Xcode and no Swift toolchain. What arrives is verified before it
  is trusted: its SHA-256 against the release's `checksums.txt`, a strict
  `codesign` check, a designated requirement demanding a genuine Developer
  ID signature (and, when configured, a specific Team ID), and the
  virtualization entitlement. It is cached at `~/.vivarium/bin/<tag>/viv`
  and moved into place only once every check has passed. Where no release
  can match the ref — used by local path, pinned to a branch or a SHA, a
  fork that publishes nothing — the Action fails with instructions rather
  than building or guessing at a tag, both of which would mean silently
  running a binary other than the one the workflow asked for.
- `examples/hello/`, a minimal committed `viv.json` project runnable as
  written.

### Changed

- Home directory moved from `~/VRE-POC` to `~/.vivarium` (override
  `VIVARIUM_HOME`), with `templates/` and `runs/<run-id>/` in place of the
  POC's flatter layout. `~/VRE-POC` is never read or written by Vivarium;
  an existing template is adopted by copying it across (see `README.md`).
- Warm-run shutdown ordering changed so that a `viv run` no longer pays for
  `selftest`'s slower, more thoroughly measured shutdown path: a warm `viv
  run` now takes roughly 35–40 seconds end to end, down from the
  proof-of-concept's ~125 second warm path.
- Default guest account renamed `vreadmin` to `vivadmin`; default artifact
  volume name renamed `VREArtifacts` to `VivArtifacts`; debug logging
  environment variable renamed `VRE_DEBUG` to `VIV_DEBUG`.

### Carried over unchanged

- The reasons a local macOS 27 IPSW is mandatory, the shutdown strategy
  (`requestStop()` given a short budget, falling back to an in-guest `sudo
  shutdown -h now`), guest-address discovery ordering, and the security
  posture around the per-run password, host-key checking, and
  `O_NOFOLLOW` marker reads — all inherited from the proof of concept and
  documented in `README.md`.
