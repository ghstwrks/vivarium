# Vivarium

Vivarium runs a test command autonomously inside a macOS virtual machine,
against a copy of your project's code. The host does everything: it clones a
template, provisions and boots a fresh guest, copies your code in, runs your
command, streams its output live, harvests whatever it produced, writes a
report, and shuts the guest down. No human touches the guest at any point.

```sh
just build
viv template create --ipsw ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw
cd ~/my-project && viv run -- swift test
```

The first command builds and signs the `viv` binary. The second restores
macOS into a template once — expect roughly two and a half minutes — from
which every later run clones a fresh guest in seconds. The third runs a
warm test: about 35–40 seconds from `viv run` to a report on Apple silicon
running macOS 27, of which roughly 17 seconds is boot-to-SSH.

Derived from the `vre-poc` proof of concept, which answered a narrower
question: whether `VZMacGuestProvisioningOptions` could get a macOS 27 guest
through first boot with no human at Setup Assistant, and whether the host
could then prove what the guest did. It could. See [History](#history).

## Requirements

- Apple silicon Mac running macOS 27 or later.
- Xcode (this uses the macOS 27.0 SDK; Command Line Tools alone are not
  enough).
- A **local** macOS 27 IPSW. There is no download fallback — see
  [Why a local IPSW](#why-a-local-ipsw-is-mandatory).
- Roughly 80 GiB free.

## Build

```sh
just build
```

Building and ad-hoc signing are one step on purpose. `swift build` produces
an unsigned binary, and Virtualization refuses to create a `VZVirtualMachine`
without `com.apple.security.virtualization`. The sign step reads the
entitlement back off the binary and fails if it is missing, so no run can
silently use an unsigned build.

## Usage

`viv help` and `viv <command> --help` describe every option; this is the
shape of each command. All flags accept both `--flag value` and
`--flag=value`.

### `viv preflight [--ipsw <path>]`

Checks the host, the entitlement, free space, and — if given — a restore
image. Creates nothing and starts no virtual machine, so it turns a
ninety-minute failure into a two-second one. Without `--ipsw` it checks only
what does not depend on an image.

### `viv template create --ipsw <path>`

Restores macOS from a local IPSW into a bundle and snapshots it, unbooted, as
a template. macOS evaluates first-boot provisioning options exactly once, on
the first boot after a restore, so every guest a run provisions must come
from a freshly restored disk; the template exists so that restore only
happens once. Expect around two and a half minutes and roughly 80 GiB of
free space. `--skip-ipsw-digest` skips hashing the restore image, which is on
by default only for `--reuse`d iteration.

### `viv template list`

Lists templates in the Vivarium home with their build, size on disk, and
creation date.

### `viv run [options] [-- <command…>]`

The core pipeline; see [How it works](#how-it-works). Takes its test command
from a trailing `-- <command…>` or from `viv.json`'s `test` field — the
command line wins. `--code <dir>` selects the project directory (default:
the working directory), `--manifest <path>` overrides the default
`<code>/viv.json`, `--template <path>` overrides the newest template in the
Vivarium home, `--timeout <seconds>` bounds the test command (default 600),
and `--keep-vm` keeps `VM.bundle` even when the test passes.

### `viv selftest [options]`

The proof of concept's thirteen-criterion acceptance run, preserved as
Vivarium's own integration test: boots a guest, authenticates over SSH,
proves stdout, stderr, and exit status are captured independently, that the
VirtioFS share and an artifact disk both survive, and that the guest shuts
down cleanly. With no path options it clones the newest template; with
`--from-template` it clones the one named; with `--ipsw` and no template it
takes the cold path — restore, snapshot, then prove — which takes around
ninety minutes. A warm run takes about two minutes, most of it a
deliberately slower measured shutdown path that `viv run` does not use. See
`POC-RESULTS.md` for a worked example and the negative-test flags
(`--share-read-only`, `--artifact-read-only`, `--disable-remote-login`).

### `viv validate --bundle <path>`

Re-checks an existing bundle's artifact disk against the expectations
recorded in its `run.json`, without starting a virtual machine. Carried over
from the proof of concept.

### `viv gc [--dry-run] [--older-than <days> | --all]`

Deletes run directories under the Vivarium home. A run that already
succeeded has nothing left to collect — its `VM.bundle` and `Shared/` are
removed automatically when it finishes — so `gc` matters for runs kept for
inspection after a failure or a timeout: it removes their heavy `VM.bundle`
and `Shared/` remains while keeping `results/`. `--dry-run` lists what would
be deleted and deletes nothing; `--older-than <days>` and `--all` choose
which runs qualify. `gc` only ever touches `<home>/runs`; it never touches
`<home>/templates`, and it never touches `~/VRE-POC`, the proof of concept's
home, which Vivarium does not read or write.

## The `viv.json` manifest

Optional. Every field can be overridden on the command line, so the
manifest records what a project usually wants rather than what a given
invocation must do.

```json
{
  "name": "my-project",
  "test": "sh run-tests.sh",
  "artifacts": ["logs/**", "results.xml"],
  "timeout": 600,
  "env": { "CI": "1" }
}
```

- `name` — a label, reported but never used as a path.
- `test` — the command, run by the guest's shell in the copied code
  directory. A trailing `-- <command…>` on the command line overrides it.
- `artifacts` — glob patterns, relative to the guest's copy of the code
  directory, whose matches are harvested. See
  [The guest contract](#the-guest-contract) for exactly how they expand.
- `timeout` — the test command's budget in seconds. `--timeout` overrides
  it.
- `env` — extra environment variables for the test command. Names must be
  valid shell identifiers and may not collide with `VIV_RUN_ID` or
  `VIV_ARTIFACTS`, which Vivarium sets itself.

Unknown keys are a hard error, not a warning. A manifest that misspells
`artifacts` as `artefacts` and has that key silently ignored is a run that
quietly harvests nothing and reports success — a far more expensive mistake
than being stopped at the typo. If neither a manifest `test` nor a trailing
command is available, `viv run` refuses to guess and prints both ways to
supply one.

## The guest contract

- **Code is copied, never mounted.** The host clones your code directory
  onto the share (`clonefile` where the volume allows it, so the copy is
  cheap even for a large repository) and the guest then copies it again,
  from the share into a guest-local working directory. The guest never
  mounts, and never writes to, your original directory. The second copy
  exists because builds and test runners hardlink, mmap, chmod, and open
  sockets, and doing that on a VirtioFS mount is a well-known source of
  failures unrelated to the code under test.
- **`$VIV_RUN_ID` and `$VIV_ARTIFACTS`** are set for the test command.
  `$VIV_RUN_ID` is this run's identifier. `$VIV_ARTIFACTS` is a guest path on
  the share; anything the test command writes there is harvested
  automatically, whether or not it matches an `artifacts` glob.
- **Artifact globs are resolved by the guest's zsh**, relative to the guest's
  copy of the code directory. `logs/**` behaves like `logs/*` — zsh's
  recursive-glob qualifier is a property of `**/`, not `**`, so a bare `**`
  matches one level; write `logs/**/*` to reach everything beneath `logs/`.
  Only regular files are harvested — a pattern that matches a directory
  harvests nothing for that match, which keeps `logs/**` from trying to copy
  a directory into itself.
- **`--timeout`** (default 600 seconds) bounds the test command alone. It
  does not bound the boot, the code staging, or the harvest; a slow build
  step inside your test command counts against it, a slow guest boot does
  not.

## Results and reports

Every run's results live at `~/.vivarium/runs/<run-id>/results/`:

```
results/
  report.json       machine-readable: status, timings, exit code, artifacts
  report.md         the same, formatted for reading
  test-stdout.txt   the test command's stdout, captured in full
  test-stderr.txt   the test command's stderr, captured in full
  run.log           Vivarium's own log for this run
  artifacts/        harvested files, mirroring the guest's working directory
```

`report.json`'s optional fields are **omitted, not `null`**, when they do
not apply. In particular, an absent `testExitCode` means the test command
never exited — a timeout, or a connection that failed underneath it — which
is a different fact from "exited nonzero" and is kept distinguishable
rather than collapsed into `null`.

## Cleanup and `gc`

A run that passes deletes its own `VM.bundle` and staged `Shared/` as its
last step, automatically, keeping only `results/`. `--keep-vm` keeps the
bundle even on success, for a run you want to poke at afterwards.

A run that fails or times out keeps everything — bundle, share, and
results — and says so: *"run kept for inspection: viv gc cleans it up
later."* Nothing is deleted on your behalf without asking, because the
guest that just failed is usually the most useful thing on the host for
working out why.

`viv gc` is that cleanup, run later and on your terms. By default it
removes the same two directories a successful run removes itself —
`VM.bundle` and `Shared/` — from every *finished* run (one that wrote a
`results/report.json` or `results/failure.json`), keeping each run's
`results/`. A run directory with a bundle but no report yet may still be
running, so it is skipped with a note. The two widening flags go further
and delete **whole run directories, results included**: `viv gc
--older-than 7` sweeps runs that finished more than a week ago, and `viv gc
--all` removes every run outright, kept-for-inspection and reportless ones
included. `viv gc --dry-run` shows exactly what any invocation would do,
computed by the same code that would do it. Templates, and anything outside
`~/.vivarium/runs/`, are never touched.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Infrastructure succeeded; the test command exited 0. |
| `1` | Infrastructure succeeded; the test command failed, or timed out. |
| `2` | Usage error. |
| `70` | Vivarium/infrastructure failure (`EX_SOFTWARE`). |

Your tests failing is not Vivarium failing. A `1` means Vivarium did its job
completely and correctly and your command was unhappy about something; a
`70` means Vivarium itself could not get far enough to ask.

## Security notes

- The generated guest password exists in process memory and in the
  environment of a short-lived askpass helper. It is never written to
  `run.json`, a log line, a command line, or a file. Because it is held in
  memory only, a bundle from an earlier invocation cannot be logged into by
  a later one — which is why `viv run` and `viv selftest` clone a fresh
  guest from a template rather than reusing one already provisioned.
- OpenSSH accepts a password only from a terminal or an askpass program, so
  the askpass helper writes a fixed two-line script into a mode-0700
  temporary directory and passes the password via the child process's
  environment, removing the directory immediately afterwards. Environment
  variables are readable by sufficiently privileged local processes; this is
  adequate for a NAT-local VM with a one-run credential and is not a
  credential-management design.
- Host-key checking is never disabled. Each run uses its own known-hosts
  file with `StrictHostKeyChecking=accept-new`, which records the guest's
  key on first contact, still refuses a *changed* key, and keeps a recycled
  NAT address from poisoning the operator's own `known_hosts`.
- Marker and manifest files on guest-writable volumes are read with
  `O_NOFOLLOW`, so a symlink planted by the guest cannot redirect a host
  read.

## How it works

`viv run`, in order: clone the newest (or given) **template** with
`clonefile`, so a large sparse system disk costs seconds and near-zero
space; **stage** the code directory onto the share, again by clonefile where
the volume allows it; **provision** and boot the guest with a per-run
password and `VZMacGuestProvisioningOptions`, so no human sees Setup
Assistant; connect over **SSH** once the guest answers, then copy the staged
code from the share into a guest-local working directory; **stream** the
test command's stdout and stderr to the terminal live while capturing both
in full, and record its exit status; **harvest** the manifest's artifact
globs plus everything under `$VIV_ARTIFACTS`, both resolved and copied by
the guest's own shell, back through the share; write the **report**
(`report.json` and `report.md`); shut the guest down; and **delete** the
bundle and share if the test passed, keeping only `results/`.

## Home directory

Everything Vivarium owns lives under `~/.vivarium` (override with
`VIVARIUM_HOME`):

```
~/.vivarium/
  templates/<build>.bundle/    restored, unbooted, cloned per run
  runs/<run-id>/
    VM.bundle/                 deleted on a passing run
    Shared/                    staged code + harvest channel; deleted on a passing run
    results/                   always kept: report.json, report.md, streams, artifacts/
```

The proof of concept's `~/VRE-POC` is never touched by Vivarium — not by
`viv run`, not by `viv gc`. An existing POC template can be adopted by
copying (APFS clone, so it costs nothing) into the new location:

```sh
mkdir -p ~/.vivarium/templates
cp -cR ~/VRE-POC/templates/26A5388g.bundle ~/.vivarium/templates/
```

## Why a local IPSW is mandatory

`VZMacOSRestoreImage.latestSupported` currently resolves to macOS 26.6.1 on
this host. A macOS 26 guest ignores provisioning options entirely and boots
into Setup Assistant, so a download fallback would produce a run that fails
for a reason that looks nothing like the actual cause. `viv template create`
and `viv selftest`'s cold path refuse to proceed without `--ipsw`, and
`viv preflight` rejects any image below major version 27.
`viv preflight --query-latest` reports what `latestSupported` currently
offers, so the day it reaches 27 the requirement can be lifted deliberately.

## History

Vivarium began as `vre-poc`, built to answer one question: could
`VZMacGuestProvisioningOptions` get a macOS 27 guest through first boot with
nobody at Setup Assistant, and could the host then prove — independently —
what the guest had done? `POC-RESULTS.md` records the answer (yes) and the
measurements behind it; `VZMacGuestProvisioning-POC-Plan.md` is the plan it
implemented. Both are historical and are not edited.

The POC's name, VREPOC ("Virtualization Reverse Engineering Proof of
Concept"), encoded an assumption that turned out to be wrong: the reverse
engineering never happened, because the public Virtualization API was
sufficient on its own. **Vivarium** replaces it — a vivarium is a sealed
enclosure in which something is kept alive so its behaviour can be
observed, which is exactly what this tool does with a macOS guest.

The Virtualization sample this project started from, Apple's [Running macOS
in a virtual machine on Apple
silicon](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon),
is vendored unmodified under `Vendor/` and excluded from the build.

## Example

`examples/hello/` is a minimal, runnable `viv.json` project. See
`examples/hello/README.md`.
