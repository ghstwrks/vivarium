#!/bin/bash
#
# Produces the `viv` binary the rest of the action runs, and the `viv-path`
# output naming it.
#
# The action's own directory is a checkout of this repository at whatever ref
# the workflow asked for, so the binary is built from it rather than downloaded:
# there is nothing to download that could be a different version from the action
# being run. The result is cached under the Vivarium home, keyed by the contents
# it was built from, so the second job on a runner pays nothing.

set -euo pipefail
. "$GITHUB_ACTION_PATH/Scripts/action/lib.sh"

home="$(vivarium_home)"

# An operator who installs viv on the runner themselves — from a release, or
# from a checkout they update on their own schedule — says so with viv-path and
# nothing is built here.
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

action="$GITHUB_ACTION_PATH"
[ -f "$action/Package.swift" ] || fail \
    "$action does not look like a Vivarium checkout (no Package.swift), so there is nothing to build. Point viv-path at an installed binary instead."

command -v swift > /dev/null 2>&1 || fail \
    "swift is not on PATH. Vivarium is built with the macOS 27 SDK, so the runner needs Xcode — Command Line Tools alone are not enough."

if [ -n "${INPUT_XCODE_PATH:-}" ]; then
    DEVELOPER_DIR="$(expand_tilde "$INPUT_XCODE_PATH")"
    export DEVELOPER_DIR
    [ -d "$DEVELOPER_DIR" ] || fail "xcode-path is $DEVELOPER_DIR, which is not a directory."
fi

# Keyed by what the build actually consumes: the sources, their names, the
# package manifests, the entitlement file, and the toolchain. A cache key that
# was the action's ref instead would hand back yesterday's binary to a workflow
# that moved its ref, and rebuild for one that did not.
key="$(
    {
        cd "$action"
        find Sources -type f | LC_ALL=C sort
        find Sources -type f | LC_ALL=C sort | tr '\n' '\0' | xargs -0 cat
        cat Package.swift Package.resolved Vivarium.entitlements
        swift --version 2>&1
    } | /usr/bin/shasum -a 256 | cut -c1-16
)"

cached="$home/bin/$key/viv"
if [ -x "$cached" ] && has_virtualization_entitlement "$cached"; then
    echo "Using the cached build $cached"
    "$cached" --version
    set_output "viv-path" "$cached"
    exit 0
fi

echo "::group::Building viv ($key)"
mkdir -p "$home/bin/$key"
# One scratch path for every build on this runner, so a rebuild after a change
# is incremental rather than a cold compile of the dependency graph. SwiftPM
# locks it, so two jobs that reach here at once queue instead of colliding.
scratch="$home/build"
if ! swift build -c release --package-path "$action" --scratch-path "$scratch"; then
    echo "::endgroup::"
    fail "swift build failed. Vivarium needs the macOS 27 SDK; check the runner's Xcode, or set the xcode-path input. See docs/github-actions.md."
fi

# Built and signed as one step, deliberately: an unsigned binary is refused by
# Virtualization at the point where a run is already several seconds in, and
# looks like a framework problem rather than a build one.
cp "$scratch/release/viv" "$cached.partial"
/usr/bin/codesign -s - --entitlements "$action/Vivarium.entitlements" -f "$cached.partial"
if ! has_virtualization_entitlement "$cached.partial"; then
    rm -f "$cached.partial"
    echo "::endgroup::"
    fail "The entitlement is missing after signing, so the binary cannot create a virtual machine."
fi
# Renamed into place only once it is signed and checked, so a job interrupted
# mid-build cannot leave a binary the next job would treat as cached.
mv "$cached.partial" "$cached"
echo "::endgroup::"

echo "Built and signed $cached"
"$cached" --version
set_output "viv-path" "$cached"
