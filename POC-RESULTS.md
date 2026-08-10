# VZMacGuestProvisioning POC — results

What `VZMacGuestProvisioning-POC-Plan.md` set out to answer, and what the
implementation in this repository actually measured on 10 August 2026.

**The central question is answered: yes.** `VZMacGuestProvisioningOptions`
creates a working administrator account and enables Remote Login on a macOS 27
guest's first boot after restore, with no human at Setup Assistant. A host-side
command line then authenticates over SSH, runs a command, captures its stdout,
stderr, and exit status independently, and finds the guest's writes on a disk
image it later detaches and mounts on its own.

## Host and guest

| | |
|---|---|
| Host | Apple silicon, macOS 27, Xcode with the macOS 27.0 SDK (26A5388f) |
| Guest | macOS 27.0.0, build 26A5388g, from a local IPSW (22.7 GB) |
| Guest account | `vreadmin`, member of `admin` (80) and `com.apple.access_ssh` (399) |
| Network | `VZNATNetworkDeviceAttachment`, guest at 192.168.64.2 |

## Acceptance criteria

Run `394049c4-8ec8-4dc5-a6b5-208e2fd6374d`, `provision --from-template
--validate-system-disk`, exit 0 in 123.6 s.

```
pass  restore image verified as macOS 27 or later before install
pass  install succeeded
pass  first-boot provisioning succeeded without Setup Assistant
pass  SSH authentication succeeded
pass  stdout token matched
pass  stderr token matched
pass  remote exit code == 23 (observed: 23)
pass  VirtioFS marker matched
pass  graceful guest stop observed
pass  artifact disk attached read-only after VM release
pass  artifact-disk marker matched
pass  artifact disk ejected
pass  optional: system-disk home marker — Marker in /Users/vreadmin/vre-result.txt matched.
```

The same marker was found in all three places it was written: the VirtioFS
share (host directory), the artifact disk (detached, reattached read-only,
validated, ejected), and the guest's home on the system disk's APFS Data
volume.

The same thirteen pass on a cold path with nothing reused. Run
`0e80b8e6-75cf-4f67-944e-f060788261ca`, `all --ipsw … --validate-system-disk`
— digest the IPSW, restore, build a run VM, provision, validate — exit 0 in
281.9 s.

## Negative tests

Each fails, and each fails for its own reason rather than a generic one.

| Flag | Result |
|---|---|
| `--share-read-only` | exit 1; guest stderr `zsh: operation not permitted: /Volumes/My Shared Files/vre-result.txt` |
| `--artifact-read-only` | exit 11; `acceptance: the artifact directory is not writable by vreadmin`, with `ls -ld` showing mode 1777 present but the attach read-only |
| `--disable-remote-login` | exit 1 after the full 600 s readiness budget; `TCP 22 is not accepting connections`, last gate passed `guest address resolved` |

The `--artifact-read-only` case is the one that proves the speaking
preconditions were worth adding: the same situation used to surface as a bare
`exit 1` with both streams empty.

## Measured timings

| Step | Time |
|---|---|
| IPSW SHA-256 (22.7 GB) | 8.4 s |
| Restore (`VZMacOSInstaller`) | 150.8 s and 152.4 s across two runs |
| Template snapshot (`clonefile`) | 0.4 s |
| Template → run bundle materialise | 0.03 s |
| Artifact disk create, partition, chmod, eject | 1.9 s |
| Guest address discovery, MAC already leased | 1.9 s, 1 attempt, `dhcp-lease` |
| Guest address discovery, MAC seen for the first time | 14.7 s, 2 attempts, `dhcp-lease` |
| Guest sshd accepting connections | 16–18 s after VM start |
| Acceptance command round trip | 0.3 s |
| `requestStop()` → guest stops | never |
| in-guest `shutdown -h now` → guest stops | ~6 s |
| Detached-disk validation and eject | ~3 s |
| **Whole run from an existing template** | **123.6 s** |
| **Whole run from the IPSW** | **281.9 s** |

The plan budgeted ninety minutes for the restore. It took two and a half.
Template cloning makes each subsequent run essentially free, which is what
makes iteration on provisioning practical at all.

The two discovery figures are the same code path with a cold and a warm
`/var/db/dhcpd_leases`. Template runs all inherit the template's persisted MAC,
so the lease from the first of them answers every later run immediately; a
freshly restored VM has a new MAC and has to wait for the guest to actually
DHCP. Neither is close to the budget, but only the cold number is honest about
what a first run costs.

## What the plan got wrong, and what the host got wrong

Seven findings, each diagnosed from a stack sample, a bisect, or a direct
measurement rather than from reading the code and guessing.

### 1. `Process.waitUntilExit()` loses termination and hangs forever

A run sat in `mach_msg` for two hours. `sample` showed
`ProcessRunner.blockingWait` → `-[NSConcreteTask waitUntilExit]`, with no
children, no zombies, and no open pipes: the `dscacheutil` child had exited in
about 70 ms. `waitUntilExit()` is a run-loop poll on the calling thread, and a
child that exits before the wakeup source is installed leaves nothing to wake
the waiter. Cured by installing `terminationHandler` *before* `run()` and
awaiting a latch, plus a 600 s default timeout on every subprocess. (`c9c32a7`)

### 2. A polling loop's outer deadline cannot rescue a stuck attempt

The loop checked its deadline *between* attempts, so one hung attempt hung the
loop for the life of the process. Each attempt is now bounded independently
(`withTimeout`, 5 minutes), which is the structural fix rather than a longer
timeout. (`c9c32a7`)

### 3. `arp -a` returns nothing, silently, to an unapproved binary

2020 bytes from an interactive shell, 0 bytes from the compiled binary.
Unaffected by the entitlement, stdin, environment, sandboxing, or redirection;
`netstat -rnl` over the same routing socket worked from both. This is macOS
Local Network privacy (TCC): the terminal has a grant, the binary does not, and
denial is exit 0 with empty output — indistinguishable from an empty cache. A
CLI cannot raise the approval prompt. Discovery now leads with
`/var/db/dhcpd_leases`, which is world-readable and maps the persisted MAC
straight to an address. Discovery went from never resolving to 1.7 s.
(`e7009d3`)

### 4. `ifconfig` indents with tabs

`parseBridgeInterfaces` split on `" "` alone, making the first field `"\tinet"`,
so no bridge interface was ever found. Two consequences: ARP priming was always
skipped, and the Bonjour subnet filter rejected *every* candidate — including,
in one logged run, the guest's actual address. (`e7009d3`)

### 5. A `diskutil`-created APFS volume is not writable by the guest

`partitionDisk` leaves the volume root `root:wheel` mode 0775. The provisioned
account is in `staff` and `admin`, not `wheel`, so it lands on the `other` bits.
The host does not see this, because it mounts image-backed volumes `noowners` —
the same directory is writable from the host and not from the guest. The host
therefore sets mode 1777 at creation, unprivileged, and the guest honours it
because the mode is on disk. Surfaced originally as an acceptance command
exiting 1 with both streams empty, since `set -eu` makes a failed `test` silent;
the script now states which precondition failed and exits 10 or 11. (`5cee300`)

### 6. `AsyncStream` terminates when its iterator is cancelled

The shutdown path waits twice: once for `requestStop()`, then again after the
in-guest fallback. Both waits consumed the same `AsyncStream` inside a task
group that calls `cancelAll()` when the timeout arm wins — and cancelling the
consumer deinitialises the iterator, which terminates the stream. The second
wait therefore observed an already-finished stream and returned "did not stop"
in the same millisecond it started. A guest that had shut down perfectly well
was destructively killed and the run failed at the last step before disk
validation. Replaced with a latch that records the terminal outcome once and
answers every caller, early or late. (`3f938f5`)

### 7. `diskutil info` does not report APFS roles

The system-disk check identifies the Data volume by role, because names are
localised and the Signed System Volume must not be opened. It asked `diskutil
info -plist` for `APFSVolumeRoles`. That key does not exist in `info` output on
any volume — verified by dumping every key — so the search found nothing while
`disk23s5 volume-name=Data` sat in the device list printed alongside the error.
`diskutil apfs list -plist` reports a `Roles` array per volume, for every
container, in one call. (`9e606a1`)

## Behaviours worth knowing

- **`requestStop()` has never once stopped a provisioned guest.** It delivers a
  power-button press, and a macOS guest with a logged-in session answers with a
  confirmation dialog nobody is there to click. The in-guest `sudo shutdown -h
  now` works every time, about six seconds later. It returns SSH exit 255,
  "Connection closed by remote host", because sshd goes down with the machine —
  that is success, not failure, and only the guest actually stopping decides it.
- **`VZMacOSRestoreImage.latestSupported` resolves to macOS 26.6.1 on this
  host**, which ignores provisioning options and boots into Setup Assistant. A
  local macOS 27 IPSW is mandatory and there is deliberately no download
  fallback.
- **The Swift API is `setGuestProvisioning(_:)`**, not the plan's
  `setGuestProvisioningOptions(_:)`. The Objective-C selector is
  `setGuestProvisioningOptions:error:`, but Swift strips the suffix matching the
  `guestProvisioningOptions` property.
- **`logsInAutomatically` is `true`**, against the plan's `false`. macOS
  automounts external volumes through `diskarbitrationd` in a console user
  session, so with nobody logged in the preformatted artifact volume may never
  appear. No acceptance criterion weakens — nobody touches Setup Assistant
  either way — and `--no-auto-login` selects the plan's original behaviour.

## Future work

Nothing below blocks the POC's conclusion; these are the things a follow-up
would want.

1. **Stop depending on the auto-logged-in session.** It exists only so
   `diskarbitrationd` mounts the artifact volume, and it is also why
   `requestStop()` never works. The acceptance script already mounts the volume
   by name as a fallback; confirm that path works unaided with
   `--no-auto-login`, and if it does, drop the session and re-test whether
   `requestStop()` becomes the primary shutdown path.
2. **Shorten the `--disable-remote-login` negative test.** It burns the full
   600 s SSH-readiness budget to prove a port is closed. A separate, much
   shorter budget for runs that *expect* no SSH would make the negative suite
   cheap enough to run every time.
3. **Password delivery.** The per-run password reaches OpenSSH through an
   askpass helper's environment, which is adequate for a NAT-local VM with a
   one-run credential and is explicitly not a credential-management design.
   Injecting an SSH public key through the provisioning options, if the API
   allows it, would remove the password from the flow entirely.
4. **Bound the artifact disk's guest-visible surface.** Mode 1777 on the volume
   root is the smallest change that works, but a dedicated directory owned by
   the provisioned account would be tighter if the account's UID were known
   before first boot.
5. **Amend the plan document.** `VZMacGuestProvisioning-POC-Plan.md` still
   states `setGuestProvisioningOptions(_:)` and that `setGuestProvisioning` does
   not exist; the opposite is true. The plan also budgets ninety minutes for a
   restore that takes two and a half, and orders discovery ARP-first. These are
   recorded in `README.md` rather than edited into the plan, which is left as
   the historical document it is.
6. **Concurrent runs.** Every run so far has been serial. Nothing obviously
   prevents several guests at once — MAC-keyed discovery would still work — but
   the `diskutil` device numbering and the `/Volumes/VREArtifacts` name would
   collide, and neither has been tested under contention.
7. **Cleanup.** `~/VRE-POC` holds every run bundle ever created. They are
   `clonefile`-shared against the template so the real cost is far below the
   319 GB nominal, but there is no retention policy and no `vre-poc gc`.
