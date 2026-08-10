# vre-poc

A command-line proof of concept for **`VZMacGuestProvisioningOptions`** on
macOS 27: restore a guest from a local IPSW, boot it once with provisioning
options so no human touches Setup Assistant, then prove from the host that the
guest ran a command, that its stdout, stderr, and exit status were captured
independently, and that its writes survived to a detached disk image.

Derived from Apple's [Running macOS in a virtual machine on Apple
silicon](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)
sample, vendored unmodified under `Vendor/` and excluded from the build. The
plan this implements is `VZMacGuestProvisioning-POC-Plan.md`.

## Requirements

- Apple silicon Mac running macOS 27 or later.
- Xcode (this uses the macOS 27.0 SDK; Command Line Tools alone are not enough).
- A **local** macOS 27 IPSW. There is no download fallback — see
  [Why a local IPSW](#why-a-local-ipsw-is-mandatory).
- Roughly 80 GiB free.

## Build

```sh
make build
```

Building and ad-hoc signing are one target on purpose. `swift build` produces
an unsigned binary, and Virtualization refuses to create a `VZVirtualMachine`
without `com.apple.security.virtualization`. The sign step reads the
entitlement back off the binary and fails if it is missing, so no run can
silently use an unsigned build.

## Use

```sh
# Check the host, entitlement, free space, and the restore image. Creates nothing.
make preflight IPSW=~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw

# The full acceptance path: restore, snapshot a template, provision, prove, validate.
.build/release/vre-poc all --ipsw ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw

# Iterate on provisioning without paying for another restore.
.build/release/vre-poc provision --from-template ~/VRE-POC/templates/26A5388g.bundle

# Re-check an existing bundle's artifact disk without starting a VM.
.build/release/vre-poc validate --bundle ~/VRE-POC/<run-id>/VM.bundle
```

`vre-poc help` lists every option. `VRE_DEBUG=1` enables debug logging.

### Why `provision` needs a template

The guest password is generated per run and held in memory only — never in
`run.json`, never in a log line, never on a command line. A bundle therefore
cannot be logged into by a *later* invocation, so `provision` clones a template
and provisions a fresh guest rather than adopting an already-booted one.

### Why a local IPSW is mandatory

`VZMacOSRestoreImage.latestSupported` currently resolves to macOS 26.6.1 on
this host. A macOS 26 guest ignores provisioning options entirely and boots
into Setup Assistant, so a download fallback would produce a run that fails for
a reason that looks nothing like the actual cause. `install` and `all` refuse
to proceed without `--ipsw`, and preflight rejects any image below major
version 27. `preflight --query-latest` reports what `latestSupported` currently
offers, so the day it reaches 27 the requirement can be lifted deliberately.

## What a run produces

```
~/VRE-POC/<run-id>/VM.bundle/
  AuxiliaryStorage  Disk.img  HardwareModel  MachineIdentifier  MACAddress
  Artifact.raw                 1 GiB RAW sparse image, APFS volume "VREArtifacts"
  Shared/                      the VirtioFS share; the guest's marker lands here
  run.json                     non-secret run metadata and expectations
  ssh-result.json              the acceptance command's captured streams
  validation.json              the detached-artifact-disk check
  failure.json                 written only on failure
  report.json                  the acceptance criteria, pass by pass
  logs/run.log  logs/install.log  logs/state.jsonl  logs/diagnostics/
```

Templates land in `~/VRE-POC/templates/<build>.bundle` and are cloned with
`clonefile`, so a 128 GiB sparse system disk costs seconds and near-zero space.

## Deviations from the plan

These are places where the implementation knowingly differs from
`VZMacGuestProvisioning-POC-Plan.md`.

### `setGuestProvisioning(_:)`, not `setGuestProvisioningOptions(_:)`

Phase 5 of the plan states the API is `setGuestProvisioningOptions(_:)` and
that "an earlier draft of this plan called it `setGuestProvisioning`, which
does not exist". The opposite holds. The Objective-C selector is
`setGuestProvisioningOptions:error:`, but Swift strips the suffix matching the
`guestProvisioningOptions` property, so it imports as
`setGuestProvisioning(_:) throws`. Compiling the plan's spelling against the
macOS 27.0 SDK (26A5388g) yields *"has been renamed to
'setGuestProvisioning(_:)'"*. The code uses the real spelling; the plan
document has not been amended.

### `logsInAutomatically` defaults to `true`

The plan specifies `false`. macOS automounts external volumes through
`diskarbitrationd` in the context of a console user session, so with nobody
logged in the preformatted APFS artifact volume may never appear in the guest —
failing the run for a reason unrelated to what is being measured.

No acceptance criterion weakens: the criterion is that no human interacts with
Setup Assistant, which still holds. The acceptance script also mounts the
volume by name as a fallback, and once that fallback is confirmed to work
unaided this can return to `false`. Either way the value used is recorded in
`run.json`, and `--no-auto-login` selects the plan's original behaviour.

### Guest discovery leads with the DHCP lease database, not ARP

The plan orders discovery ARP first. In practice `arp -a` enumerates the local
network, which macOS gates behind Local Network privacy: an interactive shell
inherits the terminal's grant, but this binary has none, and denial is silent —
exit 0, no output, empty stderr, indistinguishable from an empty cache. A CLI
cannot raise the approval prompt, so the strategy contributes nothing on a
stock host.

Discovery therefore leads with `/var/db/dhcpd_leases`, written by the DHCP
server behind Virtualization's NAT. It is world-readable, needs no permission,
and maps the bundle's persisted MAC straight to an address. ARP remains as a
second strategy for hosts where the permission has been granted, and Bonjour
last, confined to the NAT bridge subnet.

### `requestStop()` never stops the guest; the in-guest shutdown always does

The plan gives graceful shutdown a single five-minute budget and treats the
in-guest `sudo shutdown -h now` as the fallback. Measured over several runs,
`requestStop()` is not the primary path at all — it has never once stopped the
guest. It delivers a power-button press, and a macOS guest with a logged-in
session answers that with a confirmation dialog nobody is there to click; the
`logsInAutomatically` deviation above guarantees such a session exists.

The fallback works every time, and the guest stops about six seconds later.
`requestStop()` therefore gets 90 seconds rather than five minutes, and the
in-guest shutdown keeps the full five. That fallback returns SSH exit 255,
"Connection closed by remote host", because sshd goes down with the machine:
that is the expected result, and whether the shutdown worked is decided only by
the guest actually stopping.

### The system disk's Data volume is found via `diskutil apfs list`

Not `diskutil info`. The optional system-disk check identifies the Data volume
by APFS role, because names are localised and the Signed System Volume must not
be the one opened. `diskutil info -plist <volume>` does not report roles at all
— no `APFSVolumeRoles` key, on any volume — so a role search built on it finds
nothing while the volume sits in plain sight. `diskutil apfs list -plist`
reports a `Roles` array per volume, for every container, in one call. Matches
are intersected with the devices the attach produced, since `apfs list` also
enumerates the host's own disks.

### The template digest covers four files, not the bundle

`template.json` records a SHA-256 over `AuxiliaryStorage`, `HardwareModel`,
`MachineIdentifier`, and `MACAddress` — not over `Disk.img`. The system disk is
a 128 GiB sparse image whose full hash costs minutes per template check, and it
is not what determines whether a platform identity is internally consistent.
Its byte count is recorded separately as a coarse integrity signal.

### The IPSW digest is computed during install, not preflight

Hashing 22 GB is noise against a ninety-minute restore but would dominate
preflight's thirty-second budget. `--skip-ipsw-digest` opts out entirely.

## Security notes

- The generated guest password exists in process memory and in the environment
  of a short-lived askpass helper. It is never written to `run.json`, a log
  line, a command line, or a file.
- OpenSSH accepts a password only from a terminal or an askpass program, so
  `AskpassHelper` writes a fixed two-line script into a mode-0700 temporary
  directory and passes the password via the child's environment, removing the
  directory immediately afterwards. Environment variables are readable by
  sufficiently privileged local processes; this is adequate for a NAT-local VM
  with a one-run credential and is not a credential-management design.
- Host-key checking is never disabled. Each run uses its own known-hosts file
  with `StrictHostKeyChecking=accept-new`, which records the guest's key on
  first contact, still refuses a *changed* key, and keeps a recycled NAT
  address from poisoning the operator's own `known_hosts`.
- Marker files on guest-writable volumes are read with `O_NOFOLLOW`, so a
  symlink planted by the guest cannot redirect a host read.
