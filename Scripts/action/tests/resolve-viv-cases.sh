#!/bin/bash
#
# Exercises Scripts/action/resolve-viv.sh against local file:// fixtures.
#
# resolve-viv.sh is where the action decides which binary to run, and it is the
# only thing standing between a workflow and executing whatever was served at a
# URL. Its refusals are therefore the security boundary, and a refusal that
# stops happening is not a failure anyone would notice: the job would go green.
# So each one is tested here.
#
# Nothing here starts a virtual machine, builds anything, or reaches the
# network. It needs a Mac — codesign and ditto — but not a hypervisor, not
# Xcode, and not a template, so it runs on a hosted macOS runner in seconds.
#
# Usage: Scripts/action/tests/resolve-viv-cases.sh

set -uo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/vivarium-resolve-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

releases="$work/releases"
base="file://$releases"
pass=0
fail=0

note() { printf '%s\n' "$*"; }

# --- Fixtures -------------------------------------------------------------

# Built from /bin/echo rather than from viv: these stand in for release assets,
# and what matters about them is how they are signed, not what they do. Using a
# system binary means this suite needs no toolchain and no macOS 27 SDK.
cat > "$work/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
PLIST

mkdir -p "$work/staging/adhoc"
cp /bin/echo "$work/staging/adhoc/viv"
codesign -s - --entitlements "$work/entitlements.plist" -f "$work/staging/adhoc/viv" 2>/dev/null \
    || { note "cannot ad-hoc sign a fixture; is this a Mac?"; exit 1; }
adhoc="$work/staging/adhoc/viv"

mkdir -p "$work/staging/unsigned"
cp /bin/echo "$work/staging/unsigned/viv"
codesign --remove-signature "$work/staging/unsigned/viv" 2>/dev/null

# A genuine Developer ID signed binary, if this machine has one. There is no
# way to manufacture one, so the cases that need it are skipped rather than
# faked — a fake would only prove the fake was rejected.
devid=""
devid_team=""
for candidate in /opt/homebrew/bin/* /usr/local/bin/* /Applications/*/Contents/MacOS/*; do
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    authority="$(codesign -d --verbose=2 "$candidate" 2>&1 | grep '^Authority=Developer ID Application:' | head -1)"
    [ -n "$authority" ] || continue
    devid="$candidate"
    devid_team="$(printf '%s' "$authority" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
    [ -n "$devid_team" ] && break
    devid=""
done

# publish <tag> <file-to-zip-as-viv>  — a well-formed release of that binary.
publish() {
    local tag="$1" binary="$2" stage
    stage="$work/staging/$tag"
    mkdir -p "$releases/$tag" "$stage"
    cp "$binary" "$stage/viv"
    (cd "$stage" && /usr/bin/ditto -c -k --sequesterRsrc viv "$releases/$tag/viv-$tag-macos-arm64.zip")
    (cd "$releases/$tag" && /usr/bin/shasum -a 256 "viv-$tag-macos-arm64.zip" > checksums.txt)
}

publish v9.9.9 "$adhoc"
publish v3.3.3 "$work/staging/unsigned/viv"

# A release whose asset is there but whose checksums.txt is not.
publish v8.8.8 "$adhoc"
rm "$releases/v8.8.8/checksums.txt"

# A checksums.txt that lists a different asset.
publish v7.7.7 "$adhoc"
sed 's/arm64/x86_64/' "$releases/v7.7.7/checksums.txt" > "$releases/v7.7.7/checksums.tmp"
mv "$releases/v7.7.7/checksums.tmp" "$releases/v7.7.7/checksums.txt"

# A checksum that does not match the bytes.
publish v6.6.6 "$adhoc"
printf '%064d  viv-v6.6.6-macos-arm64.zip\n' 0 > "$releases/v6.6.6/checksums.txt"

# An asset that is not an archive at all.
mkdir -p "$releases/v5.5.5"
printf 'this is not a zip\n' > "$releases/v5.5.5/viv-v5.5.5-macos-arm64.zip"
(cd "$releases/v5.5.5" && /usr/bin/shasum -a 256 viv-v5.5.5-macos-arm64.zip > checksums.txt)

# A well-formed archive with no viv in it.
mkdir -p "$releases/v4.4.4" "$work/staging/other"
printf 'hello\n' > "$work/staging/other/README"
(cd "$work/staging/other" && /usr/bin/ditto -c -k --sequesterRsrc README "$releases/v4.4.4/viv-v4.4.4-macos-arm64.zip")
(cd "$releases/v4.4.4" && /usr/bin/shasum -a 256 viv-v4.4.4-macos-arm64.zip > checksums.txt)

[ -n "$devid" ] && publish v1.1.1 "$devid"

# --- The harness ----------------------------------------------------------

home="$work/home"
out="$work/out"
mkdir -p "$home"

# case <name> <expected regex> <expected status> [NAME=value …]
#
# env -i because the point is what the script does with the variables the
# action gives it, and a stray VIVARIUM_HOME or GITHUB_ACTION_REF from whatever
# is running this would quietly change the answer.
case_is() {
    local name="$1" want="$2" want_status="$3"; shift 3
    local output status
    rm -rf "$out"; mkdir -p "$out"
    output="$(
        env -i \
            PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            HOME="$work/fakehome" \
            GITHUB_ACTION_PATH="$repo" \
            GITHUB_OUTPUT="$out/github_output" \
            RUNNER_TEMP="$out" \
            VIVARIUM_HOME="$home" \
            "$@" \
            /bin/bash "$repo/Scripts/action/resolve-viv.sh" 2>&1
    )"
    status=$?
    if [ "$status" = "$want_status" ] && printf '%s' "$output" | grep -qE "$want"; then
        note "ok   $name"
        pass=$((pass + 1))
    else
        note "FAIL $name (exited $status, wanted $want_status matching /$want/)"
        printf '%s\n' "$output" | sed 's/^/       | /'
        fail=$((fail + 1))
    fi
}

check() {
    if [ "$2" = "$3" ]; then
        note "ok   $1"
        pass=$((pass + 1))
    else
        note "FAIL $1 (was \"$2\", wanted \"$3\")"
        fail=$((fail + 1))
    fi
}

skip() { note "skip $1 ($2)"; }

# --- No release to match --------------------------------------------------

case_is "used by local path" \
    "used by local path.*viv-path" 1

case_is "a repository but no ref and no version" \
    "Could not tell which version" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium

case_is "pinned to a branch" \
    'pinned to "main", which is not a release tag' 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=main

case_is "pinned to a commit" \
    "not a release tag" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium \
    GITHUB_ACTION_REF=0123456789abcdef0123456789abcdef01234567

# --- viv-path -------------------------------------------------------------

case_is "viv-path that is not executable" \
    "not an executable file" 1 \
    INPUT_VIV_PATH="$work/nowhere/viv"

case_is "viv-path without the entitlement" \
    "not signed with com.apple.security.virtualization" 1 \
    INPUT_VIV_PATH=/bin/ls

case_is "viv-path is used as given" \
    "Using the viv given by viv-path" 0 \
    INPUT_VIV_PATH="$adhoc"

# --- What the release does or does not contain ----------------------------

case_is "no such release" \
    "No viv-v0.0.0-macos-arm64.zip in the v0.0.0 release" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v0.0.0 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "release without checksums.txt" \
    "has no checksums.txt" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v8.8.8 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "checksums.txt that does not list the asset" \
    "does not list viv-v7.7.7-macos-arm64.zip" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v7.7.7 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "checksum that does not match" \
    "does not match its checksum" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v6.6.6 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "asset that is not an archive" \
    "not a readable zip archive" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v5.5.5 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "archive without viv in it" \
    "does not contain viv at its root" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v4.4.4 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "version input overrides the ref" \
    "No viv-v2.2.2-macos-arm64.zip" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=main \
    INPUT_VERSION=v2.2.2 INPUT_DOWNLOAD_BASE_URL="$base"

# --- Signatures -----------------------------------------------------------

case_is "unsigned asset" \
    "does not have a valid signature" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v3.3.3 \
    INPUT_DOWNLOAD_BASE_URL="$base"

# The one that matters most. This asset's checksum is correct, it unpacks, and
# it carries the virtualization entitlement — everything an attacker who could
# replace both the asset and checksums.txt would arrange. It is refused anyway,
# because it is not Developer ID signed.
case_is "ad-hoc signed asset, correct checksum" \
    "not signed by the expected Developer ID" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v9.9.9 \
    INPUT_DOWNLOAD_BASE_URL="$base"

case_is "no configured team is a warning, not silence" \
    "::warning title=Vivarium::No expected signing team" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v9.9.9 \
    INPUT_DOWNLOAD_BASE_URL="$base"

if [ -n "$devid" ]; then
    # A real Developer ID signature gets *past* the signature check and stops
    # at the entitlement check, which is the only way to show the accept path
    # without a released viv to hand.
    case_is "a genuine Developer ID signature is accepted" \
        "not signed with com.apple.security.virtualization.*fault in the release" 1 \
        GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v1.1.1 \
        INPUT_DOWNLOAD_BASE_URL="$base"

    case_is "pinned to the team that signed it" \
        "not signed with com.apple.security.virtualization" 1 \
        GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v1.1.1 \
        INPUT_EXPECTED_TEAM_ID="$devid_team" INPUT_DOWNLOAD_BASE_URL="$base"

    case_is "pinned to a different team" \
        "not signed by the expected Developer ID \(team AAAAAAAAAA\)" 1 \
        GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v1.1.1 \
        INPUT_EXPECTED_TEAM_ID=AAAAAAAAAA INPUT_DOWNLOAD_BASE_URL="$base"
else
    skip "the Developer ID accept path" "no Developer ID signed binary on this machine"
fi

# --- The cache ------------------------------------------------------------

# Every refusal above happened before the move into place, so there is nothing
# to find. A partial or unverified binary left behind would be worse than the
# failed download: the next job would treat it as a cache hit.
if [ -e "$home/bin" ]; then
    note "FAIL a refused download left something in the cache"
    find "$home/bin" | sed 's/^/       | /'
    fail=$((fail + 1))
else
    note "ok   no refused download cached anything"
    pass=$((pass + 1))
fi

mkdir -p "$home/bin/v9.9.9"
cp "$adhoc" "$home/bin/v9.9.9/viv"
case_is "a cached binary is used without downloading" \
    "Using the cached v9.9.9 binary" 0 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v9.9.9 \
    INPUT_DOWNLOAD_BASE_URL="file://$work/nonexistent"
check "the cache hit set viv-path" \
    "$(grep '^viv-path=' "$out/github_output" 2>/dev/null)" \
    "viv-path=$home/bin/v9.9.9/viv"

# An unentitled binary in the cache is not a hit: it is a leftover from
# something that went wrong, and using it would fail later and less clearly.
codesign --remove-signature "$home/bin/v9.9.9/viv" 2>/dev/null
case_is "an unentitled cached binary is not a hit" \
    "No viv-v9.9.9-macos-arm64.zip" 1 \
    GITHUB_ACTION_REPOSITORY=rxbynerd/vivarium GITHUB_ACTION_REF=v9.9.9 \
    INPUT_DOWNLOAD_BASE_URL="file://$work/nonexistent"

note ""
note "$pass passed, $fail failed"
[ "$fail" = 0 ]
