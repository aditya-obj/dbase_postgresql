#!/usr/bin/env bash
# File: tool/check.sh
# Purpose: The full local gate for dabase_postgresql. Run it before asking
# for review; CI runs the same steps.
#
#   tool/check.sh                      # from the package directory
#   FUZZ_SEED=123 tool/check.sh        # replay a fuzz run
#
# Integration tests need a server and are not part of this gate; see
# test/docker/README.md (`dart test -P integration`).
set -euo pipefail

cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }

step 'dart pub get'
dart pub get

step 'dart format --output=none --set-exit-if-changed .'
dart format --output=none --set-exit-if-changed .

step 'dart analyze --fatal-infos'
dart analyze --fatal-infos

step 'dart test'
dart test

step 'dart test -P fuzz'
dart test -P fuzz

printf '\nAll checks passed.\n'
