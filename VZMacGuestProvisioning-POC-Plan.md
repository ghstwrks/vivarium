# Proof of concept: provision a macOS VM, execute over SSH, and validate detached storage

## Goal

Extend Apple's Swift `InstallationTool` sample into a command-line proof of concept that can perform this complete workflow without Setup Assistant interaction:

1. Create a new VM bundle and restore macOS into its system disk.
2. Reconstruct the installed VM with the same Mac platform identity.
3. Attach a writable VirtioFS host share and a separate writable Virtio block artifact disk.
4. Start the VM for the first time with `VZMacGuestProvisioningOptions`.
5. Wait until the provisioned account and Remote Login are ready.
6. Discover the guest's network address.
7. Execute a command over SSH.
8. Capture the remote command's stdout, stderr, and exit status independently.
9. Have the command write a known marker into:
   - the VirtioFS mount, proving host-directory sharing; and
   - the separate Virtio block disk, proving guest writes survive detachment.
10. Gracefully shut down the guest.
11. Release all VM/storage objects.
12. Attach the artifact disk read-only on the host and validate its marker.
13. Optionally attach the system disk read-only and validate a marker in the provisioned user's home directory.

The separate artifact disk is deliberate. A VirtioFS path is backed by a host directory, not by the VM's disk image, so it can be validated directly but cannot satisfy a detached-disk-image validation by itself.

## Environment verification

The following was measured on this host on 2026-08-10. Facts recorded here are verified, not assumed; do not re-derive them, but do re-check them if the host is upgraded.

| Item | Verified state |
|---|---|
| Host OS | macOS 27.0, build `26A5388g` |
| Architecture | `arm64` |
| Free space | ~1.0 TiB on `/System/Volumes/Data` |
| Toolchain | Apple Swift 6.4 (`swiftlang-6.4.0.27.1`), default target `arm64-apple-macosx27.0` |
| SDKs | `MacOSX27.0.sdk` and `MacOSX27.sdk` present under Command Line Tools; Xcode 27.0 also installed |
| `xcode-select` | Points at `/Library/Developer/CommandLineTools`, so `xcodebuild` is unavailable without `sudo xcode-select --switch` |
| Codesigning identities | **Zero** valid identities (`security find-identity -v -p codesigning`) |
| Provisioning API | `VZMacGuestProvisioningOptions` present in the macOS 27 SDK with `fullName`, `username`, `password`, `logsInAutomatically`, `enablesRemoteLogin` |
| Restore image | `~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw` loads as version `27.0.0`, build `26A5388g`, `hardwareModel.isSupported == true`, minimum 2 CPUs / 4 GiB |
| `VZMacOSRestoreImage.latestSupported` | Returns **26.6.1** (`25G76`) — too old for provisioning. The local IPSW must be used |

Two consequences follow, and both are load-bearing for the rest of this document.

**The framework cannot supply a usable guest image.** `fetchLatestSupported` returns macOS 26.6.1, and the provisioning header states that guests earlier than macOS 27 ignore these settings entirely. A run that silently falls back to the downloadable image would restore for roughly ninety minutes and then land in Setup Assistant. The download path is therefore removed from the acceptance workflow, and a version gate (Phase 3) is mandatory.

**Ad-hoc code signing is sufficient.** A `swiftc`-built binary signed with `codesign -s - --entitlements` was confirmed to pass the `com.apple.security.virtualization` entitlement check: `VZVirtualMachine(configuration:)` rejected the test configuration on validity grounds (`"auxiliaryStorage" is nil`), which it only reaches after the entitlement check. No Apple Developer account, provisioning profile, or `xcode-select` change is required.

## Source baseline

Use the Apple sample at:

```text
/Users/rubynerd/Downloads/RunningMacOSInAVirtualMachineOnAppleSilicon
```

The relevant Swift files are:

```text
Swift/InstallationTool/main.swift
Swift/InstallationTool/MacOSVirtualMachineInstaller.swift
Swift/InstallationTool/MacOSRestoreImage.swift
Swift/Common/Path.swift
Swift/Common/MacOSVirtualMachineConfigurationHelper.swift
Swift/Common/MacOSVirtualMachineDelegate.swift
```

The inspected checkout is commit:

```text
32fd50d874b6bab37b146eef14153fa8ccf6d111
```

Do not begin by editing the only downloaded copy. That checkout stays pristine as the upstream reference.

### Repository layout

The POC lives in a new git repository at `/Users/rubynerd/Developer/vre`, already initialised on branch `main`. Vendor the needed sample sources into it rather than working in `~/Downloads`, preserving Apple's `LICENSE.txt` alongside the copied files and recording the upstream commit (`32fd50d`) in the commit message that introduces them.

## Platform requirements

Every requirement below is satisfied on this host; see [Environment verification](#environment-verification) for the measured values.

- Apple silicon host;
- macOS 27 or later host;
- macOS 27 SDK (Command Line Tools is sufficient — Xcode is not required);
- a macOS 27-or-later restore image, supplied locally;
- `com.apple.security.virtualization` entitlement, applied by ad-hoc signature;
- network access sufficient for guest DHCP and host-to-guest SSH;
- enough free host storage for the restored system disk and test disks.

## Build and code signing

The Apple sample ships an Xcode project whose `InstallationTool-Swift` target sets `MACOSX_DEPLOYMENT_TARGET = 14.0`, `SWIFT_VERSION = 5.0`, `CODE_SIGN_STYLE = Automatic`, and `CODE_SIGN_IDENTITY = "Mac Developer"`. On this host that project cannot build: `xcodebuild` is not reachable through the current `xcode-select` setting, and there are no signing identities for automatic signing to select.

Build the POC as a Swift package instead.

- Deployment target `.macOS("27.0")`, so no `#available(macOS 27.0, *)` wrapping is needed anywhere. This is deliberately a macOS-27-only experiment.
- Swift 6 language mode, consistent with the concurrency assumptions elsewhere in this plan (`@MainActor` orchestrator, `Sendable` value types).
- One executable target. Add `swift-nio-ssh` only if and when the future SSH implementation is adopted; the initial proof shells out to `/usr/bin/ssh` and needs no dependencies.

Signing is a required post-build step, not an optional one — an unsigned binary cannot instantiate `VZVirtualMachine`:

```sh
swift build -c release
codesign -s - --entitlements InstallationTool.entitlements -f .build/release/vre-poc
```

The entitlements file is the sample's `InstallationTool.entitlements` verbatim: a single `com.apple.security.virtualization` boolean. Wire this into a `Makefile` or shell script so that no run can accidentally use an unsigned binary, and have the tool verify its own entitlement at startup rather than crashing with an uncaught `NSInvalidArgumentException` deep inside VM construction.

## Acceptance criteria

One invocation of the final `all` workflow succeeds only if every assertion below passes.

### Installation

- The restore image reports `operatingSystemVersion.majorVersion >= 27` **before** installation begins.
- A fresh VM bundle is created.
- `VZMacOSInstaller` completes successfully.
- The system disk, auxiliary storage, hardware model, and machine identifier exist.
- A pristine template copy of the bundle is taken after restore and before first boot.
- No human interacts with Setup Assistant.

### Provisioning and boot

- The provisioned username can authenticate over SSH.
- Remote Login is enabled by provisioning options rather than manual guest interaction.
- The VirtioFS share appears in the guest.
- The artifact APFS volume appears in the guest.

### SSH execution

- A deliberately chosen stdout token is captured.
- A different deliberately chosen stderr token is captured.
- A deliberately nonzero remote exit code, for example 23, is captured as 23 rather than collapsed into a generic failure.
- Transport failures are distinguishable from remote-command failures.

### Persistence and shutdown

- The marker exists in the host VirtioFS directory.
- The VM shuts down gracefully and reaches `.stopped`.
- The artifact disk is not attached to a live VM when host validation begins.
- The artifact disk attaches read-only on the host.
- Its marker exactly matches the expected run ID and content digest.
- The disk is cleanly ejected after validation.

### Optional stronger assertion

- A marker written to the provisioned user's home directory is visible after attaching the system disk read-only and locating the APFS Data volume.

## Proposed command-line interface

Refactor the sample from a single implicit behavior into explicit subcommands:

```text
vre-poc preflight [--ipsw PATH]
vre-poc install --ipsw PATH [--bundle PATH] [--template PATH]
vre-poc provision --bundle PATH [--from-template PATH] [--keep-going]
vre-poc run --bundle PATH [--guest-address ADDRESS]
vre-poc validate --bundle PATH
vre-poc all --ipsw PATH [--bundle PATH] [--template PATH]
```

`--ipsw` is required wherever an image is needed. There is no download fallback: on this host `VZMacOSRestoreImage.latestSupported` resolves to macOS 26.6.1, which would produce a guest that silently ignores provisioning. `preflight` may *query* and report what `latestSupported` currently offers, so the restriction can be lifted once Apple publishes a 27 image, but it never downloads and never substitutes an image for the one given.

`preflight` performs every cheap check before anything expensive happens: entitlement present on the running binary, host version, free space, IPSW loads, IPSW major version >= 27, `hardwareModel.isSupported`, and CPU/memory minimums. It exits nonzero on any failure and never creates a bundle. Run it first; it turns a ninety-minute failure into a two-second one.

`--keep-going` leaves a failed run's VM booted so the guest can be inspected over SSH before shutdown, rather than tearing down the only evidence.

For the first implementation, `all` is the primary acceptance path. Separate commands are valuable for debugging expensive phases without reinstalling macOS.

Suggested defaults:

```text
~/VRE-POC/<run-UUID>/VM.bundle/          # working bundle for this run
~/VRE-POC/templates/<ipsw-build>.bundle/ # pristine post-restore template
```

Suggested bundle contents:

```text
VM.bundle/
  AuxiliaryStorage
  Disk.img
  HardwareModel
  MachineIdentifier
  MACAddress
  Artifact.raw
  Shared/
    input/
    output/
  ssh_known_hosts
  run.json
  ssh-result.json
  validation.json
  logs/
```

The IPSW deliberately lives outside the bundle. It is 22.6 GB, it is shared across runs, and copying it per run would dominate both time and disk. Reference it by path and record its digest in `run.json`.

Template bundles hold only the platform identity and restored system disk, plus a `template.json` recording the source IPSW build and digest:

```text
<ipsw-build>.bundle/
  AuxiliaryStorage
  Disk.img
  HardwareModel
  MachineIdentifier
  MACAddress
  template.json
```

Do not reuse `~/VM.bundle` implicitly. A unique run directory prevents collisions and makes failed runs independently inspectable.

## High-level architecture

```text
POCOrchestrator (@MainActor)
    |
    +-- PreflightChecker
    |     entitlement, host version, space, IPSW version gate
    |
    +-- BundleManager
    |     creates paths, run manifest, credentials, marker
    |
    +-- TemplateManager
    |     clones post-restore bundle; restores from template
    |
    +-- RestoreImageManager
    |     loads local macOS 27 IPSW; asserts major version >= 27
    |
    +-- VMConfigurationFactory
    |     install configuration: system disk only
    |     run configuration: system + artifact + VirtioFS
    |
    +-- MacOSInstaller
    |     invokes VZMacOSInstaller and awaits completion
    |
    +-- GuestProvisioner
    |     creates first-boot start options and starts VM
    |
    +-- GuestAddressResolver
    |     fixed MAC -> ARP/Bonjour/override address
    |
    +-- SSHCommandRunner
    |     password auth, stdout, stderr, remote exit status
    |
    +-- VMShutdownCoordinator
    |     requestStop(), delegate completion, timeout fallback
    |
    +-- DiskImageValidator
          read-only attach, mount, verify, eject
```

Keep all `VZVirtualMachine` creation and state-changing calls on the main actor/main queue. Move process I/O, hashing, and disk inspection off the main actor.

## Why installation and first boot need separate VM configurations

Apple's sample creates one VM configuration with a single system disk and passes it to `VZMacOSInstaller`.

For this POC, do not expose the artifact disk during installation unless experiments prove the installer's target-selection behavior is unambiguous. Instead:

1. construct the install VM with only the system disk;
2. await successful installation;
3. release the installer and install-time `VZVirtualMachine`;
4. construct a new VM from the saved platform identity;
5. attach the installed system disk first;
6. attach the artifact disk second;
7. attach the VirtioFS directory-sharing device;
8. start that VM with provisioning options.

The hardware model, machine identifier, and auxiliary storage must match the values created for installation. Device lists such as directory shares and additional data disks can be added to the subsequent run configuration.

## File-level change plan

### `Path.swift`

Replace global fixed paths with a value type:

```swift
struct VMBundlePaths: Sendable {
    let root: URL
    let auxiliaryStorage: URL
    let systemDisk: URL
    let hardwareModel: URL
    let machineIdentifier: URL
    let macAddress: URL
    let artifactDisk: URL
    let sharedDirectory: URL
    let knownHosts: URL
    let runManifest: URL
    let sshResult: URL
    let validationResult: URL
}
```

Create every directory explicitly and reject an existing nonempty bundle unless `--reuse` is supplied.

### `MacOSVirtualMachineConfigurationHelper.swift`

Split the existing helper into reusable functions:

- `makePlatformForInstall(requirements:paths:)`;
- `loadInstalledPlatform(paths:)`;
- `makeSystemDisk(paths:)`;
- `makeArtifactDisk(paths:)`;
- `makeVirtioFileSystemShare(paths:)`;
- `makeNetworkDevice(macAddress:)`;
- `makeInstallConfiguration(...)`;
- `makeRunConfiguration(...)`.

Persist the randomly generated MAC address instead of hardcoding `d6:a7:58:8e:78:d4`. The address is needed for guest IP discovery and must remain stable across the install/run reconstruction.

### `MacOSVirtualMachineInstaller.swift`

Convert callback-only methods into awaitable operations, or place a continuation wrapper around the existing completion handlers.

The install method should return only after:

- `VZMacOSInstaller` reports success;
- its progress observation is invalidated;
- the VM is stopped;
- installation objects are eligible for release.

Do not call `dispatchMain()` forever after success. The current sample is an educational installer, not an orchestrated CLI.

### `MacOSVirtualMachineDelegate.swift`

Replace direct `exit()` calls with continuations or async streams that report:

- guest-requested stop;
- stop with error;
- state transitions if separately observed.

The orchestrator, not the delegate, owns process exit status.

### New files

Add:

```text
POCOrchestrator.swift
PreflightChecker.swift
TemplateManager.swift
GuestProvisioner.swift
GuestAddressResolver.swift
SSHCommandRunner.swift
ProcessRunner.swift
ArtifactDiskManager.swift
DiskImageValidator.swift
RunManifest.swift
ShellEscaping.swift
```

## Phase 1: create deterministic run metadata

Generate at the start of each run:

- run UUID;
- username, for example `vreadmin`;
- display name, for example `VRE Administrator`;
- cryptographically random password;
- random locally administered MAC address;
- marker nonce;
- expected stdout token;
- expected stderr token;
- expected remote exit code, initially 23;
- timestamps;
- host and SDK versions;
- restore-image digest.

Store non-secret metadata in `run.json`. Keep the password in memory. If persistence is necessary for a multi-command workflow, store it in the user's login keychain or in a mode-0600 file with an explicit warning and delete it after the test. Never print it in normal logs or embed it in an SSH command line.

## Phase 2: prepare the storage artifacts

### System disk

Retain Apple's current behavior, but note what that actually resolves to here. The sample's `createDiskImage()` branches on `#available(macOS 16.0, *)`, so on this macOS 27 host it **always** takes the ASIF path and shells out to `diskutil image create blank --fs none --format ASIF --size 128GiB`. The RAW branch is dead code on this machine.

- Keep ASIF for the system disk.
- Keep a 128 GiB logical size unless a smaller value is proven sufficient for the selected restore image.
- Because the system disk is ASIF, optional Phase 12 depends on `diskutil image attach` accepting ASIF read-only. That is an open question; the artifact disk deliberately does not share this dependency.

### Artifact disk

Use a small RAW disk image for the proof because it is simple to attach with both Virtualization and host disk-image tooling.

This sequence was executed end-to-end on this host and works as written:

1. Create a sparse 1 GiB RAW file with `open` and `ftruncate`.
2. `diskutil image attach --noMount <path>` — attaches without mounting; on a blank image this prints the device node (`/dev/disk16` in the trial run).
3. `diskutil partitionDisk <device> GPT APFS VREArtifacts 100%` — creates the GPT map and a single APFS volume, and mounts it.
4. `diskutil eject <device>`.
5. Attach it to the VM with `VZDiskImageStorageDeviceAttachment` and `VZVirtioBlockDeviceConfiguration`.

Take structured output from `diskutil image --plist attach ...`. Note the flag position: `--plist` is an option of the `image` verb, so `diskutil --plist image attach` is rejected. The plist is a `system-entities` array whose elements carry `dev-entry`, `content-hint`, and — for mounted volumes — `volume-name`, `filesystem-type`, and `mount-point`. Locate the artifact by matching `volume-name == "VREArtifacts"` on an entry whose `content-hint` is `Apple_APFS_Volume`.

Never identify the new device by assuming it is the highest `/dev/diskN`; parse the attach command's result.

When constructing the Virtualization attachment, choose full synchronization for the acceptance test:

```swift
let attachment = try VZDiskImageStorageDeviceAttachment(
    url: paths.artifactDisk,
    readOnly: false,
    cachingMode: .automatic,
    synchronizationMode: .full
)

let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
device.blockDeviceIdentifier = "vre-artifacts"
```

Full synchronization plus a graceful guest shutdown reduces ambiguity when validating persistence.

## Phase 3: install macOS

Keep the Apple sample's restore-image and requirements checks, and add a version gate ahead of them:

1. load the local IPSW with `VZMacOSRestoreImage.load(from:)`;
2. **assert `restoreImage.operatingSystemVersion.majorVersion >= 27`, failing immediately if not**;
3. select `mostFeaturefulSupportedConfiguration`;
4. verify the hardware model is supported;
5. create auxiliary storage using that hardware model;
6. generate and persist a machine identifier;
7. create the system disk;
8. configure CPU and memory at or above minimum requirements;
9. configure the system disk as the only storage device;
10. validate the VM configuration;
11. invoke `VZMacOSInstaller` and observe progress;
12. await success.

Step 2 is the single highest-value check in the plan. The IPSW available here reports `27.0.0` / `26A5388g`, but nothing prevents a future run from being pointed at the 26.6.1 image that `latestSupported` offers, and the failure mode is a ninety-minute install followed by a Setup Assistant prompt that no acceptance criterion can satisfy. Record the version and build in `run.json`.

Do not carry the sample's `validateSaveRestoreSupport()` call into the run configuration. Save/restore imposes restrictions the run VM deliberately violates by attaching a directory-sharing device and a second block device. Keeping it during installation is harmless because the install configuration has neither; asserting it against the run configuration would fail for reasons unrelated to this POC.

Persist an installation log containing every progress update with a monotonic timestamp.

After installation, nil out or otherwise release:

- the `VZMacOSInstaller`;
- the install-time VM;
- install-time storage attachment objects;
- KVO observations.

Do not delete the IPSW until the run is fully successful if it would be expensive to reacquire. The current image is 22.6 GB.

## Phase 3.5: snapshot the restored bundle before first boot

macOS evaluates `VZMacGuestProvisioningOptions` only on the first boot after restore, and the framework cannot use them to reconfigure a guest it has already provisioned. Every failed experiment in Phases 5 through 9 therefore consumes one restore. Without mitigation, each debugging cycle costs roughly ninety minutes, which is the difference between a POC that can be iterated on in an afternoon and one that cannot.

Immediately after installation succeeds and all install-time objects are released, and strictly **before** the first provisioned start, copy the whole bundle to a template:

```text
~/VRE-POC/templates/<ipsw-build>.bundle/
```

Requirements:

- copy with `clonefile`-backed APFS cloning (`FileManager.copyItem` on APFS, or `cp -c`) so a 128 GiB sparse system disk costs seconds and near-zero space rather than a full duplication;
- copy `AuxiliaryStorage`, `Disk.img`, `HardwareModel`, `MachineIdentifier`, and `MACAddress` together — the platform identity must stay internally consistent;
- do **not** copy `Artifact.raw`, `Shared/`, or any result file; those are per-run and are recreated by `provision`;
- record the IPSW build and a digest of the template contents in a `template.json`, and refuse to use a template whose IPSW build does not match the requested image;
- treat the template as immutable. `--from-template` clones it into a fresh run bundle; it never boots the template in place, because doing so would consume the template's one provisionable first boot.

`provision --from-template` then costs about the time of one clone plus one boot, and can be repeated as often as needed. `all` still performs a full install so that the acceptance run remains a genuine end-to-end proof.

## Phase 4: construct the first-boot VM

Load the exact platform identity saved during installation:

```swift
let platform = VZMacPlatformConfiguration()
platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: paths.auxiliaryStorage)
platform.hardwareModel = VZMacHardwareModel(
    dataRepresentation: try Data(contentsOf: paths.hardwareModel)
)!
platform.machineIdentifier = VZMacMachineIdentifier(
    dataRepresentation: try Data(contentsOf: paths.machineIdentifier)
)!
```

Configure storage in this order:

1. installed system disk;
2. artifact disk.

Configure a writable VirtioFS share:

```swift
let directory = VZSharedDirectory(
    url: paths.sharedDirectory,
    readOnly: false
)
let share = VZSingleDirectoryShare(directory: directory)
let fileSystem = VZVirtioFileSystemDeviceConfiguration(
    tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
)
fileSystem.share = share
configuration.directorySharingDevices = [fileSystem]
```

On supported macOS guests the automount tag should expose the share under `/Volumes/My Shared Files/`. The command must still check the actual mount before writing rather than assuming it appeared instantly.

Use the persisted MAC address with the existing NAT attachment:

```swift
let network = VZVirtioNetworkDeviceConfiguration()
network.macAddress = persistedMACAddress
network.attachment = VZNATNetworkDeviceAttachment()
configuration.networkDevices = [network]
```

## Phase 5: configure first-boot provisioning

Create provisioning options immediately before the first post-restore start. The spelling below is taken from the macOS 27 SDK headers on this host, not inferred:

```swift
func makeStartOptions(credentials: GuestCredentials) throws
    -> VZMacOSVirtualMachineStartOptions {
    let provisioning = VZMacGuestProvisioningOptions()
    provisioning.fullName = credentials.fullName
    provisioning.username = credentials.username
    provisioning.password = credentials.password
    provisioning.logsInAutomatically = true
    provisioning.enablesRemoteLogin = true

    let options = VZMacOSVirtualMachineStartOptions()
    try options.setGuestProvisioningOptions(provisioning)
    return options
}
```

Three details, all confirmed against `VZMacGuestProvisioningOptions.h`, `VZGuestProvisioningOptions.h`, and `VZMacOSVirtualMachineStartOptions.h`:

- The setter is `setGuestProvisioningOptions:error:`, which Swift refines to `setGuestProvisioningOptions(_:) throws`. An earlier draft of this plan called it `setGuestProvisioning`, which does not exist.
- `setGuestProvisioningOptions` validates internally and leaves the current options unchanged if validation fails, so a separate `try provisioning.validate()` call is redundant. `validateWithError:` is still available on the base class if a distinct pre-flight error is wanted; if so, expect a `VZError` carrying a guest-provisioning error code.
- `VZGuestProvisioningOptions` marks `init` and `new` as unavailable, but `VZMacGuestProvisioningOptions` redeclares `init`, so `VZMacGuestProvisioningOptions()` is correct.

No `@available(macOS 27.0, *)` guard is needed because the package's deployment target is macOS 27.

**Assumption — `logsInAutomatically` is set to `true`.** The plan originally specified `false`. It is raised here because macOS automounts external volumes through `diskarbitrationd` in the context of a console user session, and with no user logged in the preformatted APFS artifact volume may never appear in the guest — which would fail the acceptance run for a reason unrelated to what is being proved. Auto-login does not weaken any acceptance criterion: the criterion is that no human interacts with Setup Assistant, and that still holds. Revert to `false` once the guest-side mount fallback in Phase 8 is confirmed to work, and record which setting was used in `run.json`.

Rules:

- use these options only on the first normal boot after restore;
- do not start once without them and then retry;
- do not mutate them after starting;
- treat a validation error as fatal before VM startup;
- do not log the password or the full options object.

Start the VM with `VZMacOSVirtualMachineStartOptions`, not the no-options `start` overload.

## Phase 6: determine guest readiness

VM `.running` means virtual CPUs are running; it does not mean provisioning, networking, or SSH are ready.

Use independent readiness gates:

1. VM reached `.running`.
2. Guest address resolved.
3. TCP port 22 accepts a connection.
4. SSH authentication succeeds.
5. A simple command such as `/usr/bin/id -un` returns the expected username.
6. VirtioFS and artifact volume paths exist and are writable.

Use bounded exponential backoff with a total deadline, for example 10 minutes for first boot. Log every retry reason without logging credentials.

## Guest address discovery

Virtualization's NAT attachment does not expose the guest's DHCP address directly through the public `VZNetworkDevice` API. Make address discovery a replaceable component.

### Strategy A: caller override

Support `--guest-address`. This is the most deterministic debugging path and should take precedence over discovery.

### Strategy B: ARP lookup by persisted MAC

Poll the host ARP table and match the normalized persisted MAC address. On Apple's NAT network, the guest commonly appears on a host bridge such as `bridge100`.

Implementation requirements:

- run `/usr/sbin/arp -an` through `Process`;
- normalize leading zeroes and case in MAC strings;
- reject incomplete entries;
- return only an IPv4 address associated with the expected MAC;
- continue polling until timeout.

If the ARP cache is not populated, identify the NAT bridge subnet and generate bounded traffic to candidate addresses before polling again. Keep this fallback conservative; do not scan unrelated interfaces.

### Strategy C: Bonjour SSH discovery

Browse `_ssh._tcp.local.` and resolve candidates. This is useful if macOS advertises Remote Login promptly, but the service name may not uniquely identify the VM. Confirm a candidate by authenticating and checking the expected username/run marker.

### Failure diagnostics

On timeout save:

- `arp -an`;
- `ifconfig` for relevant bridge interfaces;
- `route -n get default`;
- VM state;
- recent Virtualization and network logs.

## Phase 7: SSH implementation

### Recommended POC implementation: system OpenSSH plus `SSH_ASKPASS`

Using `/usr/bin/ssh` keeps the first proof small and makes stdout, stderr, and termination status easy to capture with `Process`.

Because the provisioned credential is initially a password, create a temporary mode-0700 askpass helper whose contents are constant:

```sh
#!/bin/sh
printf '%s\n' "$VRE_SSH_PASSWORD"
```

Pass the password only in the child process environment. Configure:

```text
SSH_ASKPASS=/absolute/path/to/helper
SSH_ASKPASS_REQUIRE=force
DISPLAY=vre-poc
VRE_SSH_PASSWORD=<in-memory password>
```

Give SSH a closed or `/dev/null` standard input so it cannot attempt terminal password entry.

Suggested arguments:

```text
-o ConnectTimeout=5
-o ConnectionAttempts=1
-o PreferredAuthentications=password,keyboard-interactive
-o PubkeyAuthentication=no
-o StrictHostKeyChecking=accept-new
-o UserKnownHostsFile=<per-run ssh_known_hosts>
-o LogLevel=ERROR
<username>@<address>
<remote command>
```

Use a per-run known-hosts file. Never globally disable host-key checking. For a test that reuses an address with a newly restored VM, delete only the per-run file, not entries from the user's normal `known_hosts`.

Security limitations of the askpass proof:

- environment variables can be observable to sufficiently privileged local processes;
- the helper and environment must be removed immediately after use;
- this is suitable for an isolated POC, not a credential-management design.

### Future implementation: SwiftNIO SSH

`apple/swift-nio-ssh` supports programmatic password authentication, session channels, stdout/stderr channel data, and remote exit-status events. It removes the askpass workaround but adds package dependencies and nontrivial channel lifecycle code.

If adopted, explicitly handle:

- `NIOSSHClientUserAuthenticationDelegate` password offers;
- host-key validation rather than unconditional acceptance;
- `.channel` versus `.stdErr` data types;
- `SSHChannelRequestEvent.ExitStatus`;
- `SSHChannelRequestEvent.ExitSignal`;
- transport close before exit status;
- command timeout and cancellation.

Do not infer a zero exit status merely because the channel closed.

## Capturing stdout, stderr, and exit status correctly

For the `Process` implementation:

```swift
struct CommandResult: Codable, Sendable {
    let executable: String
    let redactedArguments: [String]
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let terminationReason: Process.TerminationReason
    let startedAt: Date
    let endedAt: Date
}
```

Attach independent `Pipe` instances to stdout and stderr. Drain both concurrently while the process runs; reading one only after process exit can deadlock if the other pipe fills.

Interpret results as:

- exit 0-254: normally the remote command's exit status;
- exit 255: SSH transport, authentication, host-key, or protocol failure;
- signal termination: local SSH process failure/cancellation.

Preserve raw byte output and provide a UTF-8 best-effort view. Do not merge stderr into stdout in the acceptance test.

## Phase 8: remote acceptance command

Use a fixed, generated script with values safely shell-escaped. It should:

1. enable strict shell behavior;
2. identify the actual VirtioFS mount;
3. identify the artifact volume by exact volume name;
4. verify both are writable;
5. write an identical marker to both;
6. write another marker to the user's home directory;
7. call `sync`;
8. emit distinct stdout and stderr tokens;
9. exit with 23.

Conceptual script:

```sh
set -eu

share='/Volumes/My Shared Files'
artifact='/Volumes/VREArtifacts'
marker='<run-id>:<nonce>:<sha256>'

# The artifact volume may not automount if no console session exists.
# Mount it explicitly by volume name before asserting on it.
if [ ! -d "$artifact" ]; then
    /usr/sbin/diskutil mount VREArtifacts
fi

test -d "$share"
test -w "$share"
test -d "$artifact"
test -w "$artifact"

printf '%s\n' "$marker" > "$share/vre-result.txt"
printf '%s\n' "$marker" > "$artifact/vre-result.txt"
printf '%s\n' "$marker" > "$HOME/vre-result.txt"

/bin/sync
printf '%s\n' 'VRE_STDOUT_OK'
printf '%s\n' 'VRE_STDERR_OK' >&2
exit 23
```

Do not inline arbitrary user input. Either implement rigorous POSIX shell quoting or encode the complete script as base64 and decode it into `zsh -s` on the guest. Remember that the SSH client exit of 23 is expected success for this test harness.

Before the acceptance command, run a readiness command that exits zero. This keeps "guest not ready" separate from the intentional exit-23 test.

## Phase 9: validate live results

Immediately after the SSH command:

- assert exit code is 23;
- assert stdout contains only/at least `VRE_STDOUT_OK` as specified;
- assert stderr contains `VRE_STDERR_OK`;
- read `Shared/vre-result.txt` directly on the host;
- compare its exact bytes with the expected marker;
- save the complete redacted SSH result to `ssh-result.json`.

If the host share marker is absent, do not proceed as if the command succeeded simply because stdout matched.

## Phase 10: shut down the VM

Prefer Virtualization's graceful request:

```swift
guard virtualMachine.canRequestStop else {
    throw POCError.guestCannotBeAskedToStop
}
try virtualMachine.requestStop()
```

Then await `guestDidStop(_:)` from the delegate and confirm state `.stopped`.

Use a generous timeout. If the request fails or times out:

1. attempt an SSH `sudo -S /sbin/shutdown -h now`, writing the password to the remote process's stdin rather than embedding it in the command;
2. wait again for `guestDidStop`;
3. use destructive `virtualMachine.stop` only as a final test-cleanup fallback;
4. mark the run failed if destructive stop was required, because disk-persistence validation would otherwise be less trustworthy.

After graceful stop:

- invalidate observations;
- release the `VZVirtualMachine`;
- release disk attachments and device configurations;
- wait briefly/retry if host disk-image attachment reports the artifact image is busy.

Do not host-attach any image that remains writable by a live VM.

## Phase 11: validate the detached artifact disk

Attach `Artifact.raw` read-only with:

```sh
diskutil image --plist attach --readOnly <path>
```

This was exercised on this host. The attach mounts the APFS volume automatically at `/Volumes/VREArtifacts`, read-only is genuinely enforced by the filesystem (`touch` fails with `Read-only file system`, and `mount` reports the `read-only` flag), a marker written before ejection reads back intact, and the plist reports:

```text
system-entities:
  disk16   GUID_partition_scheme
  disk16s1 Apple_APFS
  disk17   Apple_APFS_Container
  disk17s1 Apple_APFS_Volume  volume-name=VREArtifacts  mount-point=/Volumes/VREArtifacts
```

Note that the container and volume appear on a *different* device number than the image's own disk, so both must be tracked for cleanup, and `diskutil eject` must target the top-level image device.

Validation algorithm:

1. Attach read-only.
2. Parse returned device identifiers from every `system-entities` element.
3. Locate the entry whose `volume-name` is exactly `VREArtifacts`.
4. Mount it read-only if `mount-point` is absent from the plist.
5. Open `vre-result.txt` without following unexpected symlinks.
6. Compare exact bytes to the expected marker.
7. Record file metadata and SHA-256.
8. Unmount/eject every device created by the attach operation in a `defer` cleanup path.

Never hardcode `/dev/disk4` or a mount path left over from an earlier run.

The validation result should include:

```json
{
  "artifactAttachedReadOnly": true,
  "volumeName": "VREArtifacts",
  "markerMatched": true,
  "markerSHA256": "...",
  "deviceIdentifiers": ["diskN", "diskNs1"],
  "ejected": true
}
```

## Optional Phase 12: inspect the installed system disk

This proves that the SSH command also changed the macOS Data volume, but it is more complex than the dedicated artifact disk.

Procedure:

1. Attach `Disk.img` read-only after VM shutdown and release.
2. Parse the partition map and APFS container.
3. Identify APFS volumes by role, not only by display name.
4. Locate and mount the Data volume read-only.
5. Read `/Users/vreadmin/vre-result.txt` from the mounted Data volume.
6. Compare the marker.
7. Record APFS volume/snapshot information.
8. Eject all attached devices.

Do not modify the Signed System Volume or its snapshots. The expected user-home file belongs on the writable Data volume.

If FileVault or another encryption mode is introduced later, this step will need explicit unlock credentials and should remain outside the initial POC.

## Orchestrator state machine

Represent orchestration as explicit states so callbacks cannot accidentally advance twice:

```text
idle
  -> preflight
  -> preparingBundle
  -> preparingRestoreImage
  -> creatingInstallVM
  -> installing(progress)
  -> releasingInstallVM
  -> snapshottingTemplate
  -> creatingRunVM
  -> startingWithProvisioning
  -> resolvingAddress
  -> waitingForSSH
  -> executingAcceptanceCommand
  -> validatingVirtioFS
  -> requestingGuestShutdown
  -> waitingForGuestStop
  -> releasingRunVM
  -> attachingArtifactReadOnly
  -> validatingArtifact
  -> ejectingArtifact
  -> succeeded
```

Every state also has a transition to `failed(stage:error:)`, followed by best-effort cleanup. Save the state transition log to the bundle.

## Async wrappers

Use checked continuations carefully:

- resume exactly once;
- retain callback-owned objects until completion;
- cancel KVO observations on every terminal path;
- bridge VM delegate events through one owner;
- use task cancellation to request operation cancellation where public APIs permit it;
- never translate task cancellation into `virtualMachine.stop()` during installation.

An `@MainActor` orchestrator can own the VM while actors or detached tasks handle process output and hashing.

## Error model

Define stage-specific errors instead of calling `fatalError`:

```swift
enum POCStage: String, Codable {
    case preflight
    case bundlePreparation
    case restoreImage
    case installation
    case templateSnapshot
    case runConfiguration
    case provisioning
    case addressDiscovery
    case sshReadiness
    case sshCommand
    case guestShutdown
    case virtioFSValidation
    case artifactAttach
    case artifactValidation
    case cleanup
}
```

Every failure report should include:

- stage;
- underlying error domain/code/description;
- VM state;
- elapsed time;
- redacted command and output;
- bundle path;
- whether cleanup completed;
- suggested manual inspection commands.

Replace the Apple sample's `try!` and `fatalError` in all modified paths. A POC intended to diagnose first-boot automation must preserve failure context.

## Timeouts

Suggested initial limits:

| Operation | Timeout |
|---|---:|
| Preflight, excluding image load | 30 seconds |
| Restore-image metadata load | 2 minutes |
| Template clone | 5 minutes |
| macOS installation | 90 minutes |
| First boot and provisioning | 15 minutes |
| Address discovery | 10 minutes |
| TCP/SSH readiness | 10 minutes within first-boot budget |
| Acceptance command | 2 minutes |
| Graceful shutdown | 5 minutes |
| Disk-image attach/mount | 2 minutes |

Timeout errors must identify the last successful readiness gate.

## Logging and secrecy

Log:

- run ID;
- state transitions;
- VM states;
- install progress;
- address-discovery strategy and non-secret results;
- SSH retry classification;
- stdout/stderr byte counts and redacted text;
- exit status;
- shutdown sequence;
- disk attach/mount/eject identifiers;
- validation hashes.

Never log:

- provisioning password;
- askpass environment;
- complete provisioning options;
- private keys if key auth is added;
- unredacted command arguments containing secrets.

## Test matrix

### Happy path

- fresh macOS 27 IPSW;
- new VM bundle;
- NAT networking;
- generated password;
- writable VirtioFS;
- writable artifact disk;
- expected exit 23;
- graceful `requestStop`;
- read-only detached validation.

### Required negative tests

1. Wrong SSH password.
2. Remote Login provisioning disabled.
3. VirtioFS directory configured read-only.
4. Artifact disk configured read-only.
5. Artifact volume name changed.
6. Guest address discovery timeout.
7. SSH transport closes before command exit.
8. Remote command exits before writing markers.
9. Graceful shutdown timeout.
10. Artifact image still busy when validation starts.
11. Marker contents differ by one byte.
12. Attempt to reuse provisioning options after the first boot.
13. Install pointed at a macOS 26 IPSW, which must be rejected by the Phase 3 version gate in seconds, before any bundle or disk is created.
14. `--from-template` pointed at a template whose recorded IPSW build does not match the requested image.
15. Unsigned binary, which must fail with a clear entitlement message rather than an uncaught exception inside `VZVirtualMachine`.

Each negative test must fail in the expected stage with useful diagnostics.

## Implementation milestones

### Milestone 0: build, sign, preflight

- Swift package builds against the macOS 27 SDK with a macOS 27 deployment target.
- Ad-hoc signing applies the virtualization entitlement, and the binary self-checks it at startup.
- `preflight --ipsw ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw` reports version 27.0.0, a supported hardware model, and sufficient space, and exits zero.

This milestone costs minutes and gates every expensive one after it.

### Milestone 1: refactor without provisioning

- Parameterized bundle paths.
- Async installer completion.
- No `fatalError` in modified orchestration paths.
- Existing install behavior still succeeds.
- Template snapshot taken after restore and before first boot.

### Milestone 2: reconstruct and boot

- Load saved platform identity.
- Build run VM separately, without `validateSaveRestoreSupport()`.
- Start and gracefully stop an already manually provisioned VM.
- `--from-template` produces a bootable run bundle in seconds rather than a reinstall.

### Milestone 3: provisioning options

- Start a freshly restored macOS 27 VM with `VZMacGuestProvisioningOptions`.
- Confirm Setup Assistant is bypassed.
- Confirm account and Remote Login exist.

Iterate this milestone from the template, not from fresh installs.

### Milestone 4: SSH command capture

- Resolve/override address.
- Authenticate.
- Capture separate stdout and stderr.
- Preserve intentional remote exit 23.

### Milestone 5: VirtioFS proof

- Guest writes host-shared marker.
- Host validates exact bytes while VM runs.

### Milestone 6: detached artifact proof

- Guest writes artifact disk marker.
- VM shuts down gracefully.
- Host attaches image read-only and validates marker.

### Milestone 7: single-command acceptance

- `all` performs every phase.
- Generates `run.json`, `ssh-result.json`, and `validation.json`.
- Exits zero only when all acceptance criteria pass.

## Resolved before implementation

These were open questions in the original draft and have been settled by direct measurement on this host.

1. **Swift spelling of the provisioning setter.** It is `setGuestProvisioningOptions(_:) throws`, and it validates internally. See Phase 5.
2. **Guest image availability.** `latestSupported` yields macOS 26.6.1, which is unusable. A local `UniversalMac_27.0_26A5388g_Restore.ipsw` is present and loads with a supported hardware model. The download path is removed from the acceptance workflow and a version gate added.
3. **Entitlement and signing.** Ad-hoc `codesign -s - --entitlements` grants `com.apple.security.virtualization`. No developer account, provisioning profile, or Xcode is required.
4. **Artifact disk lifecycle.** Create/attach/partition/format/eject/re-attach-read-only was run end-to-end successfully, including read-only enforcement and structured plist parsing. See Phases 2 and 11.
5. **ASIF on this host.** The sample always takes the ASIF branch on macOS 27; the RAW branch is unreachable.

## Known uncertainties to resolve during implementation

1. Confirm whether the provisioned account is an administrator; do not depend on this for the primary `requestStop` path.
2. Confirm the actual VirtioFS automount path on the selected guest build.
3. Confirm whether the preformatted Virtio block APFS volume automounts during first boot, and whether the `logsInAutomatically = true` assumption in Phase 5 is what makes it work. The Phase 8 script now mounts by volume name as a fallback; determine whether that fallback is load-bearing.
4. Confirm that Remote Login as enabled by provisioning permits password authentication for the provisioned user, and whether that user is placed in the SSH access group or access is left open to all users.
5. Confirm NAT ARP discovery reliability on macOS 27 and record the actual bridge name.
6. Confirm OpenSSH returns the remote status unchanged for the chosen command and that stderr remains distinct from local SSH diagnostics.
7. Confirm the sample's ASIF system disk can be attached read-only by current `diskutil image` commands for optional system-disk inspection. This affects only optional Phase 12.
8. Confirm all disk-image objects are released before host attachment; add bounded retry for transient busy errors.
9. Confirm that `clonefile`-based bundle cloning produces a template whose restored system disk boots identically to the original. If cloning proves unreliable, fall back to a full copy and accept the cost.

These are test questions, not reasons to weaken the acceptance criteria.

## References

- Apple sample overview: <https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon>
- Installing macOS in a VM: <https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine>
- `VZMacGuestProvisioningOptions`: <https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions>
- `enablesRemoteLogin`: <https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions/enablesremotelogin>
- `VZMacOSVirtualMachineStartOptions`: <https://developer.apple.com/documentation/virtualization/vzmacosvirtualmachinestartoptions>
- `VZVirtioFileSystemDeviceConfiguration`: <https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration>
- VirtioFS automount tag: <https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration/macosguestautomounttag>
- SwiftNIO SSH: <https://github.com/apple/swift-nio-ssh>

## Definition of done

The POC is complete when a clean run produces a machine-readable report proving all of the following:

```text
restore image verified as macOS 27 or later before install
install succeeded
first-boot provisioning succeeded without Setup Assistant
SSH authentication succeeded
stdout token matched
stderr token matched
remote exit code == 23
VirtioFS marker matched
graceful guest stop observed
artifact disk attached read-only after VM release
artifact-disk marker matched
artifact disk ejected
```

The strongest final demonstration is a repeatable `all` command that can run twice into two fresh bundles without manual guest interaction and produce two independently valid reports.
