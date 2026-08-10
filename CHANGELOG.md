# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet follow Semantic Versioning strictly — see
`DESIGN-0.1.md` for what v0.1 deliberately leaves out.

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
  the host terminal as they are produced, not only after the command exits.
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
- `viv gc`, for cleaning up runs kept after a failure or timeout:
  `--dry-run`, `--older-than <days>`, and `--all`, touching only
  `<home>/runs`.
- `viv preflight`, `viv template create`/`viv template list`, `viv
  validate`, and `viv selftest` (the POC's thirteen-criterion acceptance
  proof, preserved as Vivarium's own integration test), each carried over
  from the proof of concept and renamed onto the new command surface.
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
