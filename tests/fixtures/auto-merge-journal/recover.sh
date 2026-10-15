#!/usr/bin/env bash
# Exercise the confirmed-outcome public operation in the disposable test home.
set -eu
. "$1/bin/fm-merge-outcome-lib.sh"
fm_merge_outcome_report "$2" "$2/state" task "$3" poll external
