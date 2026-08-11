# shellcheck shell=bash
# Shared by the steps of action.yml. Sourced, never executed.

# Where Vivarium keeps its templates and runs.
#
# Resolved the same way `viv` resolves it — an empty VIVARIUM_HOME means unset,
# and a leading tilde is expanded — so that a path this action prints, uploads,
# or deletes from is the same path the binary used. The one thing not repeated
# here is `viv`'s refusal of a home that is `/` or your home directory itself:
# `viv` refuses those, and it refuses them first.
vivarium_home() {
    local home="${VIVARIUM_HOME:-}"
    [ -n "$home" ] || home="$HOME/.vivarium"
    case "$home" in
        "~") home="$HOME" ;;
        "~"/*) home="$HOME/${home#\~/}" ;;
    esac
    printf '%s' "$home"
}

# Sets a step output. Values here are identifiers, paths, and numbers, so a
# newline in one means something has gone wrong upstream rather than that the
# heredoc form is needed — and a newline written plainly would let the value
# forge an output of its own.
set_output() {
    # A literal newline, not $(printf '\n'): command substitution strips
    # trailing newlines, so that spelling compares against the empty string and
    # matches every value there is.
    local newline='
'
    case "$2" in
        *"$newline"*)
            fail "the value for the \"$1\" output contains a line break"
            ;;
    esac
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# Fails the step with an annotation, so the reason is on the job's summary page
# and not only in a log nobody expands.
fail() {
    printf '::error title=Vivarium::%s\n' "$1"
    exit 1
}

# The tilde a workflow author writes in a path input, expanded. The runner does
# not expand it: an input is a string, not a word the shell has seen.
expand_tilde() {
    case "$1" in
        "~") printf '%s' "$HOME" ;;
        "~"/*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Whether a binary carries the entitlement without which Virtualization refuses
# to create a virtual machine. Checked here as well as by `viv preflight`,
# because a binary that was built but not signed fails several steps later with
# an error about the framework rather than about the build.
has_virtualization_entitlement() {
    /usr/bin/codesign -d --entitlements - "$1" 2>&1 | /usr/bin/grep -q "com.apple.security.virtualization"
}
