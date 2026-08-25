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
- **Fedora guests.** `viv template create --os fedora` downloads the disk
  image Fedora publishes, checks it against a SHA-256 pinned in Vivarium's
  own source, decompresses it, and grows it to 64 GiB — about half a minute,
  with nothing to download by hand and no `xz` or `qemu-img` needed on the
  host. `viv run` then boots a clone of it in around 21 seconds end to end,
  of which ~19 is boot-to-SSH. Everything else works as it always has: the
  code is copied rather than mounted, the test command's streams are
  captured separately, artifacts are harvested through the share, and a
  passing run deletes its own bundle.
- **A seam for the guest's operating system.** `GuestOS` is the name the
  outside world uses — `--os fedora`, the `os` field in a template's
  `template.json`, a column in `viv template list`, a field in
  `report.json` — and `GuestPlatform` is everything behind it: which files a
  template carries, whether a run inherits its MAC address, how a credential
  comes to exist, what the guest is asked to run, which shutdown mechanism
  goes first, what the host must be, and which acceptance criteria apply. One
  conformance per operating system; `Orchestrator`'s pipeline asks rather
  than assumes. A distribution that publishes a cloud image should be a case
  in `GuestOS` and an entry in `LinuxImageCatalogue`, and no new platform
  code.
- `--os <name>` on `viv run`, `viv selftest`, and `viv preflight`, to pick
  among the templates in a home that holds more than one guest. A run
  otherwise takes the newest template of any guest and says which it picked;
  the guest itself always comes from the template, never from a flag.
- `--command <script>` on `viv run`: the same thing as the words after `--`,
  for a caller holding the command as one string. The GitHub Action uses it,
  which is also what lets the action's `command:` input work on a Fedora
  guest — it used to wrap the command in a `zsh -c` that a Fedora guest does
  not have.
- `--image`, `--image-url` with `--image-sha256`, and `--disk-size` on
  `viv template create`, for importing a disk image Vivarium does not have
  pinned, or giving the guest more room than 64 GiB. `--disk-size` applies to
  a macOS restore too.
- An `os` input on the GitHub Action, and a serial console recorded to
  `logs/console.log` for a guest that has one — the only account of a Linux
  guest that fails before sshd, and where cloud-init's own output goes.
- A test target: the guest scripts, the template record's compatibility with
  the one 0.1 wrote, the cloud-init documents, and the xz decoder. `just
  test`, and a step in the dogfood workflow. `viv selftest` remains the
  integration test, because it is the half that needs a hypervisor.
- Unit tests for manifest and environment parsing, and for the run-storage
  deletion `viv gc` relies on.

### Changed

- `template.json` gained `os`, `osVersion`, `osBuild`, `source`,
  `sourceSHA256`, and `systemDiskSHA256`, and `platformIdentitySHA256` became
  optional. **Templates created by 0.1 are read unchanged** — the older
  `ipswBuild`, `ipswVersion`, and `ipswSHA256` are still accepted, and a
  macOS template written now carries both sets of names so that a 0.1 binary
  can still read it. A restore is ninety minutes of somebody's afternoon.
- New templates are named `<os>-<build>.bundle` rather than `<build>.bundle`.
  Existing ones keep their names and work as they always did: what a template
  is comes from its `template.json`, never from its directory name.
- `viv selftest` on a guest whose platform does not claim the artifact-disk
  proof reports those three criteria as **not asserted**, with the reason,
  rather than as passed — and refuses the macOS-only flags that go with them
  (`--artifact-volume-name`, `--artifact-read-only`, `--disable-remote-login`,
  `--validate-system-disk`) instead of ignoring them.
- `report.json` from `viv run` gained `guestOS` and `guestOSVersion`;
  `run.json` gained `guestOS` and renamed the fields that were named for an
  IPSW. The selftest's own record renamed
  `restoreImageVerifiedAsMacOS27OrLater` to `guestImageAccepted` and
  `installSucceeded` to `guestImagePrepared`, because a Fedora template is
  imported rather than restored and neither old name was true of it.
- The README, the generated CLI help, and the Action documentation now
  describe what the code does: `--keep-vm` retains both `VM.bundle` and
  `Shared/`, the `viv.json` fields an invocation can override are named
  accurately, and the measured restore duration is distinguished from the
  ninety-minute budget the installation is allowed. Implementation comments
  describe current invariants rather than past debugging history.

### Security

- A Linux guest authenticates by SSH key rather than by password. cloud-init
  reads its instructions from a seed image that sits in the run's bundle for
  as long as the guest lives, so a password in it would be a password written
  to disk — which the macOS path goes to some trouble never to do. The seed
  carries the public half of an ed25519 pair generated for the run; the
  private half is `id_ed25519` in the same bundle, mode 0600, and goes when
  the bundle does. The guest keeps its distribution's own refusal of password
  logins over SSH rather than having Vivarium turn that off.
- Published images are pinned by digest. A hostile mirror serving something
  else through Fedora's download redirector gets refused before anything is
  unpacked, and `--image-url` requires `--image-sha256` for the same reason.
- macOS's xz decoder stops at the end of the first stream, so a file holding
  several concatenated would decompress to a silently truncated disk image.
  Anything left unread after the stream ends is refused rather than ignored.

### Fixed

- `viv gc --all` now removes dangling symlinks under `runs/` as links. The
  safety model already refused to follow these entries, but the final removal
  used an existence check that follows symlinks and therefore treated a link to
  a missing target as if the link itself did not exist.
- Manifest validation now rejects NUL bytes in test commands, environment
  values, and artifact patterns, and rejects every Unicode line separator in
  artifact patterns. These values are passed through shell strings or a
  line-oriented here-document and cannot be represented faithfully otherwise.

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
