# Vivarium

Vivarium runs a test command autonomously inside a fresh virtual machine,
against a copy of your project's code. The host does everything: it clones a
template, provisions and boots a fresh guest, copies your code in, runs your
command, streams its output live, harvests whatever it produced, writes a
report, and shuts the guest down. No human touches the guest at any point.

Two guests, on the same Apple silicon host:

```sh
just build

# a Fedora guest: about half a minute to build the template
viv template create --os fedora
cd ~/my-project && viv run -- ./run-tests.sh

# a macOS guest: about ninety minutes, once, from a local restore image
viv template create --ipsw ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw
cd ~/my-project && viv run -- swift test
```

`just build` builds and signs the `viv` binary. `viv template create` makes
the guest once; every later run clones it in a fraction of a second.
`viv run` then takes about 35–40 seconds end to end for a macOS guest (~17 s
of it boot-to-SSH) and about 21 seconds for a Fedora one (~19 s of it
boot-to-SSH).

Which guest a run uses comes from its template, so only `viv template
create` has to be told. With templates for both in the home, `viv run --os
fedora` picks which.

Derived from the `vre-poc` proof of concept, which answered a narrower
question: whether `VZMacGuestProvisioningOptions` could get a macOS 27 guest
through first boot with no human at Setup Assistant, and whether the host
could then prove what the guest did. It could. See [History](#history).

## Requirements

- Apple silicon Mac running macOS 27 or later.
- Xcode (this uses the macOS 27.0 SDK; Command Line Tools alone are not
  enough).

For a **macOS** guest, additionally:

- A **local** macOS 27 IPSW. There is no download fallback — see
  [Why a local IPSW](#why-a-local-ipsw-is-mandatory).
- Roughly 80 GiB free.

For a **Fedora** guest:

- Roughly 20 GiB free, and a network connection the first time.

Nothing else is needed on the host: the disk image is fetched over HTTPS
and decompressed in-process with the `Compression` framework, so there is
no `xz`, `qemu-img`, or package manager in the way.

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

### `viv preflight [--os <name>] [--ipsw <path>]`

Checks the host, the entitlement, free space, and — if given — a restore
image. Creates nothing and starts no virtual machine, so it turns a
ninety-minute failure into a two-second one. The thresholds depend on the
guest: `--os fedora` needs neither macOS 27 nor 80 GiB, and checking it
against the stricter numbers would refuse a host perfectly capable of
running it.

### `viv template create [--os <name>] …`

Makes a guest that has never been started, which every run then clones. The
two guests get there by genuinely different routes, and the flags say so.

**macOS** is restored: `--ipsw <path>` is mandatory, it takes around ninety
minutes, and it needs roughly 80 GiB free. macOS evaluates first-boot
provisioning options exactly once, on the first boot after a restore, so the
template is snapshotted before that boot is spent. `--skip-ipsw-digest`
skips hashing the restore image, for `--reuse`d iteration.

**Fedora** is imported: `viv template create --os fedora` downloads the disk
image Fedora publishes, checks it against a SHA-256 pinned in Vivarium's own
source, decompresses it, and grows it to 64 GiB. Expect about half a minute.
Three ways to point it elsewhere:

| flag | for |
|---|---|
| `--image <path>` | a raw or `.xz` image already on this machine |
| `--image-url <url> --image-sha256 <hex>` | a different published image |
| `--disk-size <gib>` | a guest that needs more room than 64 GiB |

The pinned image is [Fedora Cloud
Base](https://fedoraproject.org/cloud/download/), not Fedora Server, and the
difference is worth knowing: Fedora Server's VM guest image is published
only as qcow2, which Virtualization cannot attach and macOS has no tool to
convert, and its raw image ships `initial-setup` rather than cloud-init, so
its first boot waits at a console prompt for a human — which Vivarium has
nobody to provide. Cloud Base is the same Fedora built to be started by a
machine. `--image` imports the Server image for anyone who converts it
themselves.

### `viv template list`

Lists templates in the Vivarium home with their guest, version, size on
disk, and creation date.

### `viv run [options] [-- <command…>]`

The core pipeline; see [How it works](#how-it-works). Takes its test command
from a trailing `-- <command…>` or from `viv.json`'s `test` field — the
command line wins. `--code <dir>` selects the project directory (default:
the working directory), `--manifest <path>` overrides the default
`<code>/viv.json`, `--template <path>` overrides the newest template in the
Vivarium home and `--os <name>` narrows that choice to one guest,
`--timeout <seconds>` bounds the test command (default 600),
and `--keep-vm` keeps `VM.bundle` even when the test passes.
`--keep-going` goes further: when a run fails, it leaves the guest running
and prints its address so you can SSH in and look at it, holding until you
press Ctrl-C — which force-stops the guest and exits with the status the run
had earned. A passing run is never held.

Two options exist for callers rather than for people. `--run-id <name>` pins
the run's identifier, and therefore `<home>/runs/<name>` — so a script knows
where the results will be before the run that writes them has started,
instead of guessing which directory was its own. `--env-file <path>` reads
`NAME=value` lines into the test command's environment, overriding the
manifest's `env`; it is a file rather than a flag because a command line is
readable by every process on the host, which makes it the wrong place for a
token. Parsing is literal, not dotenv: everything after the first `=` is the
value, quotes and `$` included.

### `viv selftest [options]`

The proof of concept's acceptance run, preserved as Vivarium's own
integration test: boots a guest, authenticates over SSH, proves stdout,
stderr, and exit status are captured independently, that the VirtioFS share
survives, and that the guest shuts down cleanly. With no path options it
clones the newest template; `--os <name>` narrows that to one guest;
`--from-template` clones the one named; and `--ipsw` with no template takes
the macOS cold path — restore, snapshot, then prove — which takes around
ninety minutes.

Three of the thirteen criteria concern a separate, detachable artifact
disk, and only a macOS guest asserts them. That proof is a statement about
the Virtualization framework — that a guest's write to a block device
survives the machine being released — rather than about any guest, so it is
made once rather than reimplemented against a filesystem both a Linux guest
and `diskutil` can agree on. A Fedora selftest reports those three as **not
asserted**, with the reason, rather than as passed; the macOS-only flags
that go with them (`--artifact-volume-name`, `--artifact-read-only`,
`--disable-remote-login`, `--validate-system-disk`) are refused rather than
silently ignored. See `POC-RESULTS.md` for a worked example and the
negative-test flags.

### `viv validate --bundle <path>`

Re-checks an existing bundle's artifact disk against the expectations
recorded in its `run.json`, without starting a virtual machine. Carried over
from the proof of concept.

### `viv gc [--dry-run] [--older-than <days> | --all]`

Deletes run directories under the Vivarium home. A run that already
succeeded has nothing left to collect — its `VM.bundle` and `Shared/` are
removed automatically when it finishes — so `gc` matters for runs kept for
inspection after a failure or a timeout: by default it removes their heavy
`VM.bundle` and `Shared/` remains while keeping `results/`. `--dry-run`
lists what would be deleted and deletes nothing. The two widening flags are
not more of the same: `--older-than <days>` and `--all` delete **whole run
directories, `results/` included**. `gc` only ever touches `<home>/runs`; it never touches
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
- **The test command is your script, run as written.** It is executed by the
  guest's own shell — `zsh` on macOS, `bash` on Fedora — with `-e` and `-u`
  off, so a multi-line `test` runs every line (a step that exits non-zero
  does not stop the ones after it) and an unset variable expands empty. The
  run's verdict is the exit status of the last line, exactly as it would be
  in a shell. Put `set -e` at the top of your own command if you want it.
- **Artifact globs are resolved by the guest's shell**, relative to the
  guest's copy of the code directory, and mean the same thing on both
  guests. `logs/**` behaves like `logs/*`: zsh treats `**` as recursive only
  when it is followed by a slash, and bash's `globstar` — which would make
  the same pattern recursive — is deliberately left off so that one
  `viv.json` does not harvest two different sets of files depending on which
  guest ran it. Write `logs/**/*` to reach everything beneath `logs/`. Only
  regular files are harvested; a pattern that matches a directory harvests
  nothing for that match, which keeps `logs/**` from trying to copy a
  directory into itself.
- **The share is where the two sides meet, and the guest owns what it sees
  there.** Apple's VirtioFS presents every file in the share to the guest as
  owned by the guest's own account, whatever the host's ownership is, so
  nothing has to reconcile a host uid with a guest one.
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
  test-stdout.txt   the test command's stdout, written as it arrives
  test-stderr.txt   the test command's stderr, written as it arrives
  run.log           Vivarium's own log for this run
  artifacts/        harvested files, mirroring the guest's working directory
```

`report.json`'s optional fields are **omitted, not `null`**, when they do
not apply. In particular, an absent `testExitCode` means the test command
never exited — a timeout, or a connection that failed underneath it — which
is a different fact from "exited nonzero" and is kept distinguishable
rather than collapsed into `null`.

Timings are recorded twice, at two resolutions. `phases` is the pipeline's own
steps — materialise, stage code, boot to ssh, prepare guest, test, harvest,
shutdown — and is what `report.md` and the terminal summary show,
because it is what a person reads after waiting for a run. `states` is the
state machine underneath it, one entry per state the run entered:

```json
"states": [
  { "state": "waitingForSSH",
    "enteredAtSeconds": 21.44,
    "seconds": 16.98,
    "enteredAt": "2026-08-19T10:02:41Z" }
]
```

`enteredAtSeconds` is an offset from the start of the run and `seconds` is
how long the run stayed in that state; the last state is closed when the
report is written, so the two account for the whole run. Both are there for
comparing runs rather than reading one: a template that boots slower after
a host upgrade, or a project whose staging cost has been creeping up, shows
in the archived reports before anyone thinks to time it. The same timeline
is in `failure.json` for a run that never reached a verdict, and appears
live in the log as `State: x -> y` lines with their elapsed offsets.

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

## Continuous integration

`action.yml` in this repository is a GitHub Action, so a downstream project
gets a fresh guest per job:

```yaml
jobs:
  test:
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@v4
      - uses: rxbynerd/vivarium@v0.1.0
        with:
          os: fedora
          command: ./run-tests.sh
```

It downloads the signed, notarised `viv` from the release matching the tag the
workflow pinned — verifying its checksum and Developer ID signature, and
caching it for later jobs — then runs the tests, writes the report to the job
summary, uploads `results/` as a workflow artifact, and reclaims disk
afterwards. The runner needs no Xcode and no Swift toolchain, but it must be
**a self-hosted Apple silicon Mac with a template already built**: GitHub's
hosted macOS runners cannot nest virtualization, and building a template is a
multi-minute operation that no workflow should perform by surprise. A runner
can hold templates for both guests; `os:` picks between them, and a matrix
over it tests a project on both.

[`docs/github-actions.md`](docs/github-actions.md) covers preparing a
runner, passing secrets, matrices, disk hygiene, and the security of running
CI on hardware you own.

## Security notes

- **The guest's credential belongs to the run**, whichever guest it is, and
  a bundle from an earlier invocation cannot be logged into by a later one —
  which is why `viv run` and `viv selftest` clone a fresh guest from a
  template rather than reusing one already provisioned.
- **A macOS guest authenticates by password.** It exists in process memory
  and in the environment of a short-lived askpass helper, and is never
  written to `run.json`, a log line, a command line, or a file. OpenSSH
  accepts a password only from a terminal or an askpass program, so the
  helper writes a fixed two-line script into a mode-0700 temporary directory
  and passes the password via the child process's environment, removing the
  directory immediately afterwards. Environment variables are readable by
  sufficiently privileged local processes; this is adequate for a NAT-local
  VM with a one-run credential and is not a credential-management design.
- **A Fedora guest authenticates by key.** cloud-init reads its instructions
  from a seed image that sits in the run's bundle for as long as the guest
  lives, so a password in it would be a password written to disk. The seed
  carries the public half of an ed25519 pair generated for the run; the
  private half is `id_ed25519` in the same bundle, mode 0600, and goes when
  the bundle does. The guest keeps its distribution's own refusal of
  password logins over SSH rather than having Vivarium turn that off. One
  consequence is a convenience rather than a compromise: `--keep-going` on a
  Fedora run prints an `ssh -i` command that actually works, which the macOS
  path cannot offer because its password is unrecoverable by design.
- **Published images are pinned by digest, not by trust in the transport.**
  `viv template create --os fedora` fetches through Fedora's mirror
  redirector and refuses anything that does not hash to the SHA-256 in
  Vivarium's own source. A hostile mirror can therefore serve nothing that
  gets unpacked. `--image-url` requires `--image-sha256` for the same
  reason.
- Host-key checking is never disabled. Each run uses its own known-hosts
  file with `StrictHostKeyChecking=accept-new`, which records the guest's
  key on first contact, still refuses a *changed* key, and keeps a recycled
  NAT address from poisoning the operator's own `known_hosts`.
- Every file the host reads back from a guest — the VirtioFS marker, the
  markers and manifests on the artifact volume — is opened with `O_NOFOLLOW`,
  so a symlink planted by the guest cannot redirect a host read. Cleanup
  likewise never relaxes permissions or flags through a symlink it finds in
  the share.

## How it works

`viv run`, in order: read the **template**'s `template.json` to learn which
guest this is, then clone it with `clonefile`, so a large sparse system disk
costs seconds and near-zero space; **stage** the code directory onto the
share, again by clonefile where the volume allows it; **provision** and boot
the guest — `VZMacGuestProvisioningOptions` with a per-run password for
macOS, so no human sees Setup Assistant, or a per-run cloud-init seed image
carrying a public key for Fedora, so no human sees a console; connect over
**SSH** once the guest answers, then copy the staged
code from the share into a guest-local working directory; **stream** the
test command's stdout and stderr to the terminal and to `results/` at once,
as they arrive, and record its exit status; **harvest** the manifest's artifact
globs plus everything under `$VIV_ARTIFACTS`, both resolved and copied by
the guest's own shell, back through the share; write the **report**
(`report.json` and `report.md`); shut the guest down; and **delete** the
bundle and share if the test passed, keeping only `results/`.

## Home directory

Everything Vivarium owns lives under `~/.vivarium` (override with
`VIVARIUM_HOME`):

```
~/.vivarium/
  templates/<os>-<build>.bundle/  restored or imported, unbooted, cloned per run
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

## Adding an operating system

`GuestOS` is the name — `--os fedora`, the `os` field in a template's
`template.json`, a column in `viv template list`, a field in `report.json` —
and `GuestPlatform` is everything behind it: which files a template carries,
whether a run inherits its MAC address, how a credential comes to exist,
what the guest is asked to run, which shutdown mechanism goes first, what
the host must be, and which acceptance criteria apply. `Orchestrator`'s
pipeline asks the platform rather than assuming.

A distribution that publishes a cloud image is expected to be one case in
`GuestOS`, one entry in `LinuxImageCatalogue`, and no new code:
`LinuxPlatform` is parameterised rather than written once per distribution.
Something genuinely different — Windows — would be a new conformance
alongside `MacOSPlatform` and `LinuxPlatform`.

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
observed, which is exactly what this tool does with a guest.

The Virtualization sample this project started from, Apple's [Running macOS
in a virtual machine on Apple
silicon](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon),
is vendored unmodified under `Vendor/` and excluded from the build.

## Example

`examples/hello/` is a minimal, runnable `viv.json` project. See
`examples/hello/README.md`.
