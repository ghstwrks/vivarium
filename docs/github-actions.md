# Vivarium as a GitHub Action

`action.yml` in the root of this repository is a composite GitHub Action that
runs a project's tests inside a fresh macOS guest and brings the results back
out. Every job gets a guest that has never been booted before, and the guest is
deleted when the job ends: a clean slate that a cached, long-lived runner
cannot give you.

```yaml
jobs:
  test:
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@v4
      - uses: rxbynerd/vivarium@v0.1.0
        with:
          command: swift test
```

## What this needs, before anything else

**A self-hosted Apple silicon runner.** This is not a preference. GitHub's
hosted macOS runners cannot run it, for two independent reasons:

1. They are themselves virtual machines, and nested virtualization is
   unavailable on them — "Nested-virtualization is not supported due to the
   limitation of Apple's Virtualization Framework"
   ([GitHub Docs, *Larger runners reference*](https://docs.github.com/en/actions/reference/runners/larger-runners);
   see also [actions/runner-images#13505](https://github.com/actions/runner-images/issues/13505)).
2. Vivarium's whole premise is a macOS 27 guest, because macOS 27 is the first
   release that honours `VZMacGuestProvisioningOptions` and so the first that
   can be brought through Setup Assistant with nobody at the keyboard. A hosted
   image running an older macOS could not host that guest even if it were
   allowed to try.

So the runner is a Mac you own, or one you rent from a provider that gives you
the bare machine rather than a VM on it.

## Preparing a runner

Once per machine. Budget an hour, most of it downloading. **No Xcode and no
Swift toolchain** — the action downloads a compiled `viv`, so the runner needs
a hypervisor and a template, not a build environment.

1. **The hardware and OS.** Apple silicon, macOS 27 or later, roughly 80 GiB
   free after everything below — a template is a full macOS install, and each
   concurrent run clones one.
2. **The Actions runner itself**, registered to the repository or organisation
   and running **as the same user that owns `~/.vivarium`**. On macOS
   `./svc.sh install` installs a LaunchAgent, which runs in that user's login
   session; the machine therefore has to be logged in (enable automatic login
   if it is headless). A runner running as a different user, or as a system
   daemon outside a login session, will not be able to create a virtual
   machine.
3. **A macOS 27 IPSW**, downloaded by hand. There is no download fallback and
   this is deliberate — see [Why a local IPSW is
   mandatory](../README.md#why-a-local-ipsw-is-mandatory).
4. **The template**, built once, from that IPSW, using a released `viv`:

   ```sh
   curl -fsSLO https://github.com/rxbynerd/vivarium/releases/download/v0.1.0/viv-v0.1.0-macos-arm64.zip
   ditto -x -k viv-v0.1.0-macos-arm64.zip .
   ./viv preflight --ipsw ~/Downloads/UniversalMac_27.0_..._Restore.ipsw
   ./viv template create --ipsw ~/Downloads/UniversalMac_27.0_..._Restore.ipsw
   ```

   Around two and a half minutes. Every later run clones this in seconds. The
   action does **not** create a template: restoring macOS is a multi-minute,
   80-GiB operation that a workflow should never perform by surprise, and the
   IPSW cannot be fetched automatically anyway. A runner without a template
   fails the job immediately, with that as the message.

That `viv` was only needed for `template create` and can be deleted afterwards;
the action fetches its own.

## Which binary the action runs

The action downloads the release matching **the ref the workflow pinned it
to**. `uses: rxbynerd/vivarium@v0.1.0` runs v0.1.0's action definition and
v0.1.0's binary — the two always agree, or the job fails saying so. It is
cached at `~/.vivarium/bin/<tag>/viv`, so only the first job on a runner pays
for the download.

Before the binary is run, in this order:

1. Its SHA-256 must match the release's `checksums.txt`.
2. `codesign --verify --strict` must pass.
3. It must satisfy a designated requirement demanding a genuine **Developer ID**
   signature, and — when a team is configured — that team's. The checksum only
   proves the bytes came from whoever served both files; the signature is what
   proves who built it.
4. It must carry `com.apple.security.virtualization`, without which it could not
   create a guest.

Notarisation is checked with `spctl` but is not fatal: a notarisation ticket
cannot be stapled to a bare executable, so the check is an online one, and a
runner behind a proxy that cannot reach Apple would otherwise be unable to run
a binary whose signature has already verified. The check produces a warning
annotation when it does not confirm.

The expected team comes from `Scripts/action/expected-signer.txt` in the action
itself, or from the `expected-team-id` input, which is what a fork signing its
own releases sets.

### When there is no release to match

The action **fails with instructions** rather than guessing. Three cases:

| Situation | Why there is no release |
|---|---|
| `uses: ./` | Used by local path, so there is no ref to have pinned. |
| `uses: owner/vivarium@main` or `@<sha>` | Releases are cut from tags. |
| A fork with no releases of its own | Nothing has been published under that name. |

Each of these needs `viv-path`, naming a signed binary installed on the runner:

```yaml
      - uses: ./
        with:
          viv-path: ${{ github.workspace }}/.build/release/viv
```

The action will not fall back to building `viv` and will not fall back to
"the newest release that exists". Both would mean a workflow silently running
a binary other than the one it asked for, which is the sort of helpfulness that
becomes a mystery two months later.

`version` overrides the ref for the rare case where running a different binary
than the action definition is the deliberate intent.

## Using it

### The manifest, or the input

The command can come from either side. A `viv.json` in the project keeps the
workflow short and keeps `viv run` locally and the Action doing the same thing:

```yaml
      - uses: rxbynerd/vivarium@v0.1.0
```

```json
{ "test": "swift test", "artifacts": ["logs/**/*"], "timeout": 900 }
```

The `command` input overrides the manifest's `test`, exactly as a trailing
`-- <command…>` does on the command line. It may be several lines, and it is
handed to the guest's shell as written:

```yaml
      - uses: rxbynerd/vivarium@v0.1.0
        with:
          command: |
            set -e
            swift build
            swift test --parallel
```

Note the explicit `set -e`. The guest runs the command with `-e` and `-u` off,
so every line runs and the verdict is the last line's exit status — the same
contract as [the guest contract](../README.md#the-guest-contract), because it
is the same code path.

### Secrets

The `env` input takes `NAME=value` lines and is where a secret belongs:

```yaml
      - uses: rxbynerd/vivarium@v0.1.0
        with:
          command: swift test
          env: |
            NPM_TOKEN=${{ secrets.NPM_TOKEN }}
            CI=1
```

The values are written to a mode-0600 file that is deleted when the step ends,
and passed to `viv` as a file rather than on a command line, where every other
process on the runner could read them out of the process table. They are not
recorded in `report.json` or `run.log`. They will appear in `test-stdout.txt`
if your own test command echoes them — which is also true of the runner's log,
and is your command's business either way.

Parsing is deliberately literal, not dotenv: everything after the first `=` is
the value, quotes and `$` included, and nothing is stripped, expanded, or
unescaped. `TOKEN=a"b$c` is those five characters. Blank lines and lines
starting with `#` are ignored. A name that is not a shell identifier, a
duplicate name, or one of `VIV_RUN_ID` / `VIV_ARTIFACTS` is refused rather than
guessed at.

The host's own environment does not reach the guest. Secrets available to the
workflow but not listed here stay on the host.

### Results

The action always writes the run's report to the job summary and uploads
`results/` as an artifact named `vivarium-<run-id>`:

```
report.json       machine-readable: status, timings, exit code, artifacts
report.md         the same, formatted for reading
test-stdout.txt   the test command's stdout
test-stderr.txt   the test command's stderr
run.log           Vivarium's own log for this run
artifacts/        whatever the manifest's globs and $VIV_ARTIFACTS collected
```

Turn either off with `summary: false` and `upload-artifacts: false`.

### Deciding for yourself

By default a failing test command fails the step. To branch on the result
instead:

```yaml
      - id: tests
        uses: rxbynerd/vivarium@v0.1.0
        with:
          command: swift test
          fail-on-test-failure: false

      - if: steps.tests.outputs.passed != 'true'
        run: echo "status=${{ steps.tests.outputs.status }} exit=${{ steps.tests.outputs.test-exit-code }}"
```

`fail-on-test-failure: false` covers exactly one case: the test command exited
nonzero or ran out of time. A usage error (exit 2) and a Vivarium failure (exit
70) still fail the step, because in neither case did your tests run, and a
green job would be a lie.

Watch the difference between `status` and `passed`. `status` is `passed`,
`failed`, `timedOut`, or `error` — the last meaning the run never reached a
verdict at all. And `test-exit-code` is **empty**, not `0`, when the command
never exited; a timeout is not an exit status.

## Inputs

| Input | Default | |
|---|---|---|
| `command` | manifest's `test` | The test command. May be several lines. |
| `working-directory` | `.` | Project directory, copied into the guest. Never mounted. |
| `manifest` | `<working-directory>/viv.json` | Path to the manifest. |
| `template` | newest in the home | Which template to clone. |
| `timeout` | manifest's, else 600 | Seconds for the test command alone. |
| `env` | — | `NAME=value` per line. Where secrets go. |
| `run-id` | derived | Names the run and its directory. |
| `keep-vm` | `false` | Keep `VM.bundle` even on a pass. |
| `vivarium-home` | `~/.vivarium` | Where templates and runs live. |
| `viv-path` | — | Use an installed `viv` instead of downloading one. Required when there is no release to match. |
| `version` | the pinned ref | Release tag to download, overriding the ref. |
| `expected-team-id` | `Scripts/action/expected-signer.txt` | Team ID the downloaded binary must be signed by. |
| `preflight` | `true` | Run `viv preflight` first. |
| `summary` | `true` | Write the report to the job summary. |
| `upload-artifacts` | `true` | Upload `results/`. |
| `artifact-name` | `vivarium-<run-id>` | Name for that upload. |
| `artifact-retention-days` | repository default | Retention for that upload. |
| `gc` | `true` | Run `viv gc` afterwards. |
| `gc-older-than` | — | Also delete whole runs older than N days. |
| `fail-on-test-failure` | `true` | Whether a failing test fails the step. |

## Outputs

| Output | |
|---|---|
| `status` | `passed`, `failed`, `timedOut`, or `error`. |
| `passed` | `true` only when the test command exited 0. |
| `exit-code` | `viv`'s exit code: 0, 1, 2, or 70. |
| `test-exit-code` | The test command's exit code; empty if it never exited. |
| `run-id` | The run's identifier, and the guest's `$VIV_RUN_ID`. |
| `run-path` | The run directory on the runner. |
| `results-path` | `results/` on the runner. |
| `report-json` | Path to `report.json`, empty if there is none. |
| `total-seconds` | Wall-clock for the whole run. |
| `artifact-count` | How many files the harvest collected. |
| `viv-path` | The binary this run used. |

## One run at a time

Vivarium v0.1 does not support concurrent runs on one host (see
`DESIGN-0.1.md`). Two jobs cloning and booting guests at once will contend for
disk, memory, and the NAT's address pool. Give the runner one job at a time:
register a single runner per machine and serialise at the workflow level.

```yaml
concurrency:
  group: vivarium-${{ github.repository }}
  cancel-in-progress: false
```

A matrix works, but its legs will queue rather than run in parallel, and each
leg needs a distinguishable run name. The default run-id is derived from the
workflow run, attempt, job, step, project directory, and command; two legs that
differ only in something the action cannot see — a matrix variable used in the
`env` input, say — derive the same name, and the second one fails saying so
rather than writing over the first one's results. Give those a `run-id`, and an
`artifact-name` to match:

```yaml
    strategy:
      matrix:
        swift: ["6.0", "6.1"]
    steps:
      - uses: rxbynerd/vivarium@v0.1.0
        with:
          command: swift test
          env: |
            SWIFT_VERSION=${{ matrix.swift }}
          run-id: ${{ github.run_id }}-${{ github.run_attempt }}-swift-${{ matrix.swift }}
          artifact-name: vivarium-swift-${{ matrix.swift }}
```

## Disk

A run that passes deletes its own guest. A run that **fails keeps everything** —
bundle, share, results — because the guest that just failed is the most useful
thing on the host for working out why. On a long-lived runner that is a full
disk by Thursday, so the action runs `viv gc` after every job, which reclaims
the heavy directories of every finished run and keeps every `results/`.

`gc-older-than: 7` goes further and deletes whole run directories, results
included, that finished more than a week ago. Set it to however long results
are worth reading *on the runner itself*; the uploaded artifact is the copy
that outlives them. Turn the whole thing off with `gc: false` if you would
rather sweep on your own schedule.

Templates are never touched by any of this.

## Security

**A self-hosted runner on a public repository is dangerous, and Vivarium does
not fix that.** Anyone who opens a pull request can propose workflow changes
that run on your hardware. Vivarium isolates the *test command* inside a
disposable guest; it does nothing about the rest of the workflow, which runs on
the host as the runner user, before and after this action. GitHub's own advice is blunt: "We recommend that you only use self-hosted
runners with private repositories. This is because forks of your public
repository can potentially run dangerous code on your self-hosted runner
machine by creating a pull request that executes the code in a workflow"
([GitHub Docs, *Manage access to self-hosted runners*](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)).
Use a private repository, or require approval for outside contributors' runs,
or accept that the host is exposed.

What Vivarium does guarantee, within the run itself:

- The project directory is **copied into the guest, never mounted**. Nothing
  the test command does can reach the checkout, the workspace, or anything else
  on the runner.
- Each run's guest is created from a template and has never been booted before,
  with a password generated for that run and held only in memory. A guest from
  one job cannot be logged into from another.
- The host's environment is not forwarded. Only what the `env` input lists
  reaches the test command.
- The guest's filesystem is gone when the job ends — unless the run failed, in
  which case it is kept for inspection and `gc` reclaims it later.

See [Security notes](../README.md#security-notes) for the rest.

## When it goes wrong

| Symptom | What it means |
|---|---|
| `No guest template in …/templates` | The runner was never prepared. Run `viv template create --ipsw <path>` on it once. |
| `missing the com.apple.security.virtualization entitlement` | A `viv` given via `viv-path` was built but not signed. `codesign -s - --entitlements Vivarium.entitlements -f <path>`. |
| `used by local path, so there is no release to download` | `uses: ./`. Pass `viv-path` — see [When there is no release to match](#when-there-is-no-release-to-match). |
| `pinned to "…", which is not a release tag` | The workflow pinned a branch or a SHA. Pin a tag, or pass `version`, or pass `viv-path`. |
| `No viv-…-macos-arm64.zip in the … release` | That tag has no release, or its release has no macOS arm64 asset. Common on a fork that has not cut its own. |
| `does not match its checksum` / `not signed by the expected Developer ID` | The download is not what the release says it is. Do not work around it; nothing is cached, and the job stopped before running anything. |
| `No expected signing team is configured` (warning) | The action checked that the binary is Developer ID signed but not by whom. Set `expected-team-id`. |
| `Gatekeeper did not confirm this binary is notarised` (warning) | Usually a runner that cannot reach Apple. The signature verified regardless. |
| Exit 70, `[provisioning]` or `[addressDiscovery]` | The guest did not come up. Check the runner is running in a login session as the user owning `~/.vivarium`, and that `run.log` in the uploaded artifact does not show it running out of disk. |
| `The run directory … already exists` | Two runs derived the same name. Give them `run-id`s. |
| The job takes ~40 s longer than the tests | That is the guest: roughly 17 s to boot to SSH, and a shutdown at the end. It is the price of the clean slate. |

Every failed run's `run.log` and `failure.json` are in the uploaded artifact,
and `failure.json` names the stage that failed. That is the first thing to
read.

## Cutting a release

Only for maintainers of this repository, or of a fork that signs its own
binaries. `.github/workflows/release.yml` builds, signs, notarises, and
publishes the asset the action downloads; pushing a `v*` tag triggers it, and
`workflow_dispatch` re-runs it against a tag that already exists.

It runs on a self-hosted Apple silicon Mac — the SDK requirement again — but it
never starts a guest, so it needs neither a hypervisor nor a template. Any Mac
with the right Xcode and the secrets below will do.

| Secret | |
|---|---|
| `APPLE_CERTIFICATE_P12` | The Developer ID Application certificate and key, base64 of a `.p12`. |
| `APPLE_CERTIFICATE_PASSWORD` | The password that `.p12` was exported with. |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (XXXXXXXXXX)`. |
| `APPLE_TEAM_ID` | The ten-character Team ID. Checked after signing. |
| `NOTARY_KEY_P8` | App Store Connect API key, base64 of the `.p8`. |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER_ID` | The issuer UUID from App Store Connect. |

Signing is not optional dressing. An unsigned binary cannot hold
`com.apple.security.virtualization`, and without that entitlement `viv` cannot
create a virtual machine at all — so a release that skipped signing would be a
release that does not work. The job fails at the signing step rather than
publishing one.

A fork that publishes its own releases must also put its own Team ID in
`Scripts/action/expected-signer.txt`, or every workflow using it must pass
`expected-team-id`. Until one of those is true the action still requires a
valid Developer ID signature, but warns that it cannot tell whose.

The job creates a keychain of its own, adds it to the search list rather than
repointing the default, and removes it with `if: always()`. That matters
because the runner is somebody's actual Mac: a job that fails halfway must not
leave it with a signing key unlocked or a broken default keychain.
