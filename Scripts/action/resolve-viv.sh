#!/bin/bash
#
# Produces the `viv` binary the rest of the action runs, and the `viv-path`
# output naming it.
#
# The binary comes from a signed, notarised GitHub release, downloaded once per
# runner and cached. Nothing here compiles anything: a runner needs macOS and a
# template, not a toolchain, and a workflow should not pay for a Swift release
# build to find out whether its own tests pass.
#
# Which release: the ref the workflow pinned the action to. That is what keeps
# the binary and the action in agreement — a workflow saying @v0.1.0 gets
# v0.1.0's action definition and v0.1.0's binary, or it gets an error, never a
# mixture of the two.

set -euo pipefail
. "$GITHUB_ACTION_PATH/Scripts/action/lib.sh"

home="$(vivarium_home)"

# An operator who installs viv themselves — from a release they unpacked, from
# a local build, from a checkout they update on their own schedule — says so
# with viv-path, and none of the rest of this happens.
if [ -n "${INPUT_VIV_PATH:-}" ]; then
    viv="$(expand_tilde "$INPUT_VIV_PATH")"
    [ -x "$viv" ] || fail "viv-path is $viv, which is not an executable file."
    has_virtualization_entitlement "$viv" \
        || fail "$viv is not signed with com.apple.security.virtualization, so it cannot create a virtual machine. Sign it with: codesign -s - --entitlements Vivarium.entitlements -f $viv"
    echo "Using the viv given by viv-path: $viv"
    "$viv" --version
    set_output "viv-path" "$viv"
    exit 0
fi

# --- Which release --------------------------------------------------------

version="${INPUT_VERSION:-}"
[ -n "$version" ] || version="${GITHUB_ACTION_REF:-}"
repository="${GITHUB_ACTION_REPOSITORY:-}"

# GITHUB_ACTION_REF and GITHUB_ACTION_REPOSITORY are both empty when an action
# is used by local path (`uses: ./`), because there is no ref to have pinned.
# That is a legitimate way to use this action — it is how this repository tests
# its own — but there is no release to go with it, so it needs viv-path.
if [ -z "$repository" ]; then
    fail "This action was used by local path, so there is no release to download. Build viv (just build) and pass its path as the viv-path input, or use the action as <owner>/vivarium@<tag>."
fi
if [ -z "$version" ]; then
    fail "Could not tell which version of the action is running, so there is no release to download. Pass the version input, or the viv-path input."
fi

case "$version" in
    v*) ;;
    *)
        # A branch or a commit SHA. Releases are cut from tags, so there is no
        # asset to fetch and no honest guess to make about which one was meant.
        fail "The action is pinned to \"$version\", which is not a release tag. Pin a released tag (uses: $repository@v0.1.0), or pass the version input naming the release to use, or build viv yourself and pass viv-path."
        ;;
esac

# --- The cache ------------------------------------------------------------

slug="$(printf '%s' "$version" | tr -c 'A-Za-z0-9._-' '-')"
cached="$home/bin/$slug/viv"
if [ -x "$cached" ] && has_virtualization_entitlement "$cached"; then
    echo "Using the cached $version binary at $cached"
    "$cached" --version
    set_output "viv-path" "$cached"
    exit 0
fi

# --- The download ---------------------------------------------------------

asset="viv-$version-macos-arm64.zip"
base="${INPUT_DOWNLOAD_BASE_URL:-https://github.com/$repository/releases/download}/$version"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vivarium-download.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "::group::Fetching $asset"
fetch() {
    # --fail so a 404 is an error rather than a file containing GitHub's
    # apology, and retries because a release download is one network round trip
    # away from failing a job that had nothing wrong with it.
    curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 2 --retry-connrefused \
        --output "$work/$2" "$base/$1" 2>&1
}
if ! fetch "$asset" "$asset"; then
    echo "::endgroup::"
    fail "No $asset in the $version release of $repository. Check that the tag names a release with a macOS arm64 asset, or pass viv-path to use a binary you installed yourself."
fi
if ! fetch "checksums.txt" "checksums.txt"; then
    echo "::endgroup::"
    fail "The $version release of $repository has no checksums.txt, so the download cannot be verified. Refusing to run an unverified binary."
fi
echo "::endgroup::"

# --- What was downloaded, and whether it is what was meant ----------------

# The checksum proves the bytes are the ones the release recorded. It is not
# what proves they came from us — the signature below is — but it catches a
# truncated download, and it fails loudly rather than at the point where a
# corrupt binary produces an incomprehensible crash.
# Tolerant about how the name is written: shasum quotes a binary-mode file with
# a leading *, and a checksums file generated from a glob carries a leading ./
# — neither of which says anything about which file is meant.
expected="$(
    awk -v name="$asset" '
        { path = $2; sub(/^\*/, "", path); sub(/^\.\//, "", path)
          if (path == name) { print $1; exit } }
    ' "$work/checksums.txt"
)"
[ -n "$expected" ] || fail "checksums.txt in the $version release does not list $asset."
actual="$(/usr/bin/shasum -a 256 "$work/$asset" | cut -d' ' -f1)"
[ "$actual" = "$expected" ] || fail "$asset does not match its checksum in the release (expected $expected, got $actual). Refusing to run it."

/usr/bin/ditto -x -k "$work/$asset" "$work/unpacked" \
    || fail "$asset is not a readable zip archive."
downloaded="$work/unpacked/viv"
[ -f "$downloaded" ] || fail "$asset does not contain viv at its root."
chmod +x "$downloaded"

# The signature is the part that matters. A checksum taken from the same
# release as the file it describes proves only that both came from whoever
# served them; a Developer ID signature proves who built it, and notarisation
# proves Apple has seen it since.
requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
team="${INPUT_EXPECTED_TEAM_ID:-}"
if [ -z "$team" ] && [ -f "$GITHUB_ACTION_PATH/Scripts/action/expected-signer.txt" ]; then
    # awk rather than grep, because grep finding nothing is a failing pipeline
    # under pipefail, and an unset team is an ordinary state here — not a reason
    # to abandon the run without a word.
    team="$(awk '
        !/^[[:space:]]*#/ { gsub(/[[:space:]]/, "")
                            if ($0 != "") { print; exit } }
    ' "$GITHUB_ACTION_PATH/Scripts/action/expected-signer.txt")"
fi
if [ -n "$team" ]; then
    requirement="$requirement and certificate leaf[subject.OU] = \"$team\""
else
    echo "::warning title=Vivarium::No expected signing team is configured, so this binary is only checked for being Developer ID signed, not for being signed by us. Set the expected-team-id input."
fi

/usr/bin/codesign --verify --strict "$downloaded" 2>&1 \
    || fail "The downloaded viv does not have a valid signature. Refusing to run it."
/usr/bin/codesign --verify -R="$requirement" "$downloaded" 2>&1 \
    || fail "The downloaded viv is not signed by the expected Developer ID${team:+ (team $team)}. Refusing to run it."
has_virtualization_entitlement "$downloaded" \
    || fail "The downloaded viv is not signed with com.apple.security.virtualization, so it cannot create a virtual machine. That is a fault in the release, not in this workflow."

# Notarisation is checked but is not fatal. A ticket cannot be stapled to a
# bare executable, so this asks Apple over the network, and a runner behind a
# proxy that cannot reach Apple would otherwise be unable to run a binary whose
# signature has already been verified above.
if ! /usr/sbin/spctl --assess --type install "$downloaded" > /dev/null 2>&1; then
    echo "::warning title=Vivarium::Gatekeeper did not confirm this binary is notarised. Its signature verified, so this is usually a runner that cannot reach Apple's notarisation service."
fi

# Moved into place only once every check above has passed, so an interrupted
# job cannot leave a partial or unverified binary that the next job would treat
# as a cache hit.
mkdir -p "$home/bin/$slug"
mv "$downloaded" "$cached.partial"
mv "$cached.partial" "$cached"

echo "Installed $version at $cached"
/usr/bin/codesign -d --verbose=2 "$cached" 2>&1 | grep -i "^Authority=" | head -1 || true
"$cached" --version
set_output "viv-path" "$cached"
