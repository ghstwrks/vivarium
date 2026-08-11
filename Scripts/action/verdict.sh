#!/bin/bash
#
# Turns viv's exit code back into the step's own success or failure.
#
# Separated from the run step so that everything between the two — the summary,
# the artifact upload, the cleanup — happens for a failed run as well as a
# passing one. Those are the runs whose results someone needs.

set -uo pipefail
. "$GITHUB_ACTION_PATH/Scripts/action/lib.sh"

exit_code="${EXIT_CODE:-}"
status="${STATUS:-}"
results="${RESULTS_PATH:-}"

where=""
[ -n "$results" ] && [ -d "$results" ] && where=" Results: $results, and in the uploaded artifact."

case "$exit_code" in
    0)
        echo "The test command passed."
        exit 0
        ;;
    1)
        # The one exit code that is a statement about the project rather than
        # about Vivarium. A workflow that wants to decide for itself — to
        # continue to a second step, to mark a job neutral — turns this off and
        # reads the outputs.
        if [ "$status" = "timedOut" ]; then
            reason="The test command ran out of time."
        else
            reason="The test command failed."
        fi
        if [ "${FAIL_ON_TEST_FAILURE:-true}" = "true" ]; then
            printf '::error title=Vivarium::%s%s\n' "$reason" "$where"
            exit 1
        fi
        printf '::warning title=Vivarium::%s Not failing the step, because fail-on-test-failure is false.%s\n' \
            "$reason" "$where"
        exit 0
        ;;
    2)
        # Usage: the action asked viv for something it does not accept. That is
        # a bug in the workflow's inputs or in the action, never a test result,
        # so fail-on-test-failure does not apply.
        printf '::error title=Vivarium::The run was rejected before it started (exit 2): check the action inputs against viv run --help.\n'
        exit 1
        ;;
    70)
        # Vivarium itself failed, so the tests never ran. Reporting this as a
        # test failure would be a lie in the direction that costs the most: a
        # red job that sends someone to look at their own code.
        printf '::error title=Vivarium::Vivarium failed, so the tests never ran (exit 70). This is a host, template, or guest fault.%s\n' "$where"
        exit 1
        ;;
    "")
        printf '::error title=Vivarium::The run step recorded no exit code.\n'
        exit 1
        ;;
    *)
        printf '::error title=Vivarium::viv exited %s, which is not an exit code it documents.%s\n' "$exit_code" "$where"
        exit 1
        ;;
esac
