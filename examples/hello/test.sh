#!/bin/sh
# A minimal Vivarium test command. Runs inside the guest, in the copied
# project directory; see ../README.md for what it demonstrates.
set -eu

echo "hello from stdout, run ${VIV_RUN_ID}"
echo "hello from stderr, run ${VIV_RUN_ID}" >&2

# Anything written under $VIV_ARTIFACTS is harvested automatically, even
# without a matching "artifacts" glob in viv.json.
echo "${GREETING}" > "${VIV_ARTIFACTS}/greeting.txt"

# This one is harvested because viv.json's "artifacts" glob matches it:
# "logs/**/*" reaches files nested under logs/, not just logs/ itself.
mkdir -p logs
echo "build finished, run ${VIV_RUN_ID}" > logs/build.log

exit 0
