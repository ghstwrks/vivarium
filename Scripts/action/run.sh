#!/bin/bash
#
# Runs `viv run` and records where its results are.
#
# This step never fails on the run's verdict. It captures viv's exit code as an
# output and returns 0, so that the steps after it — the summary, the artifact
# upload, the cleanup — happen for a failed run, which is the run whose results
# anyone actually needs. The verdict is turned back into a step failure at the
# end of the action.

set -eo pipefail
. "$GITHUB_ACTION_PATH/Scripts/action/lib.sh"

home="$(vivarium_home)"

# --- The project directory ------------------------------------------------

code="$(expand_tilde "${INPUT_WORKING_DIRECTORY:-.}")"
case "$code" in
    /*) ;;
    *) code="$PWD/$code" ;;
esac
[ -d "$code" ] || fail "working-directory is $code, which is not a directory."

# --- The run's name -------------------------------------------------------

# A named run has a known directory, which is the whole reason to name it: the
# steps after this one can collect the results without having to guess which of
# the directories under runs/ was this job's.
run_id="${INPUT_RUN_ID:-}"
derived="false"
if [ -z "$run_id" ]; then
    # The workflow run and attempt make this unique across time; the job, the
    # step, and a digest of what is being run separate the legs of a matrix,
    # which are otherwise indistinguishable from here — a composite action
    # cannot see the matrix that produced it. GITHUB_ACTION carries a _2, _3
    # suffix when one job uses an action more than once, which is what keeps two
    # identical steps in one job apart.
    job="$(printf '%s' "${GITHUB_JOB:-job}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)"
    leg="$(
        printf '%s\n%s\n%s\n' "$code" "${INPUT_COMMAND:-}" "${GITHUB_ACTION:-}" \
            | /usr/bin/shasum -a 256 | cut -c1-8
    )"
    run_id="gha-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}-${job}-${leg}"
    derived="true"
fi

run_path="$home/runs/$run_id"
results_path="$run_path/results"

# viv refuses to reuse a run directory, and is right to: the results in it
# belong to a run that already happened. Caught here so the reason names the
# thing the workflow can change, rather than arriving as a generic Vivarium
# failure several seconds later.
if [ -e "$run_path" ]; then
    if [ "$derived" = "true" ]; then
        fail "The run directory $run_path already exists. Two legs of a matrix that differ only in something this action cannot see — a matrix variable used in the env input, say — derive the same name. Give each one its own run-id input."
    fi
    fail "The run directory $run_path already exists, so the run-id input $run_id is already taken on this runner."
fi

set_output "run-id" "$run_id"
set_output "run-path" "$run_path"
set_output "results-path" "$results_path"

# --- The template ---------------------------------------------------------

# Checked here only when the run would fall back to the newest template in the
# home, which is the case where "no template" means the runner was never set
# up. A named template is viv's to validate.
if [ -z "${INPUT_TEMPLATE:-}" ]; then
    if ! ls -d "$home"/templates/*.bundle > /dev/null 2>&1; then
        fail "No guest template in $home/templates. A runner has to be prepared once, from a local macOS 27 restore image: viv template create --ipsw <path>. See docs/github-actions.md."
    fi
fi

# --- The environment for the test command ---------------------------------

env_file=""
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
    [ -n "$env_file" ] && rm -f "$env_file"
    return 0
}
trap cleanup EXIT

if [ -n "${INPUT_ENV:-}" ]; then
    # Written where only this user can read it, and removed on the way out.
    # The values are read by viv and exported inside the guest; they are never
    # passed on a command line, where every other process on the runner could
    # read them out of the process table.
    env_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vivarium-env-$$"
    (
        umask 077
        printf '%s\n' "$INPUT_ENV" > "$env_file"
    )
fi

# --- The invocation -------------------------------------------------------

args=(run --code "$code" --run-id "$run_id")
[ -n "${INPUT_MANIFEST:-}" ] && args+=(--manifest "$(expand_tilde "$INPUT_MANIFEST")")
[ -n "${INPUT_TEMPLATE:-}" ] && args+=(--template "$(expand_tilde "$INPUT_TEMPLATE")")
[ -n "${INPUT_TIMEOUT:-}" ] && args+=(--timeout "$INPUT_TIMEOUT")
[ -n "$env_file" ] && args+=(--env-file "$env_file")
[ "${INPUT_KEEP_VM:-false}" = "true" ] && args+=(--keep-vm)

# The command reaches the guest as one argument to its own shell rather than as
# a list of words. Splitting it here would mean this shell deciding where a
# quoted argument in someone else's test command ends, and a multi-line command
# has no word-splitting reading at all. `zsh -c` is what viv would have used
# anyway: the guest runs the command under zsh with -e and -u off, and so does
# this.
if [ -n "${INPUT_COMMAND:-}" ]; then
    args+=(-- zsh -c "$INPUT_COMMAND")
fi

set +e
"$VIV" "${args[@]}"
exit_code=$?
set -e

set_output "exit-code" "$exit_code"
if [ -d "$results_path" ]; then
    set_output "results-exist" "true"
else
    set_output "results-exist" "false"
fi

exit 0
