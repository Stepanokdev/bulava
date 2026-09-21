#!/usr/bin/env bash
#
# Project verification for this repo, for the engine's verifier to call.
#
# Why this file exists: the generic Xcode step picks `schemes[0]` from
# `xcodebuild -list`, and in this workspace that is WhisperKit's
# `argmax-oss-swift-Package` — a Swift-package dependency scheme with no test bundle.
# The step therefore built a dependency and reported "no test bundles available", so every
# run's evidence came back inconclusive no matter what the code did. The scheme this repo
# actually ships is named after the project, and it has the tests.
#
# Contract with the engine: exit 0 = verified, non-zero = failed.
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

PROJECT="Night Shift.xcodeproj"
SCHEME="Night Shift"
LOG="$(mktemp -t night-verify)"

# Its OWN build directory, and this is not tidiness.
#
# Verification builds with CODE_SIGNING_ALLOWED=NO, which produces an ad-hoc, linker-signed app
# whose code identifier is `Night Shift` rather than `stepanok.com.Night-Shift` and which carries
# no team. Sharing Xcode's DerivedData meant every verification silently REPLACED the app the
# director actually launches with that one — a different application as far as macOS is concerned.
# TCC keys its grants on exactly that identity, so Screen Recording, Accessibility and automation
# were revoked by the act of running the tests, and the next night's worker could not take a
# screenshot. Building somewhere else leaves his signed build untouched.
#
# Persistent rather than a fresh mktemp: incremental builds are the difference between one minute
# and ten.
DD="${TMPDIR:-/tmp}/bulava-verify-dd"

echo "→ xcodebuild test -scheme '$SCHEME' (derivedDataPath: $DD)"

# CODE_SIGNING_ALLOWED=NO: an unattended run has no interactive keychain, and signing is
# irrelevant to whether the code compiles and the tests pass.
#
# PRODUCT_BUNDLE_IDENTIFIER: the other half of the fix the comment above describes, and the half
# that was missing. Building somewhere else stopped verification from OVERWRITING the installed
# app — but the suite still LAUNCHES what it built, and what it built is ad-hoc signed (code
# identifier `Bulava`, no team) while still claiming `stepanok.com.Night-Shift`. macOS keys a
# privacy grant to a bundle identifier together with the code identity allowed to use it, so a
# second, differently-signed program claiming the director's identifier leaves the stored grant
# no longer matching the app it was given to. The switch in System Settings goes on reading ON,
# ScreenCaptureKit answers "the user declined", and the next night's worker cannot take a
# screenshot — which is exactly what it did, twice, and cost an evening the second time.
#
# Under its own identifier the test build is simply a different application, and running the
# suite can no longer touch what the director granted.
run_tests() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER=stepanok.com.Night-Shift.verify \
    test > "$LOG" 2>&1
}

run_tests
rc=$?

# A pruned module cache is not a broken tree, and it must never read as one.
#
# $DD lives under TMPDIR for the incremental speed, and macOS prunes /var/folders on its own
# schedule. It takes the .pcm files out from under a build database that still references them, so
# every compile then dies with "module file ... not found" and xcodebuild reports TEST FAILED —
# "Testing cancelled because the build failed". A release stopped on that, saying the tests did not
# pass, about a tree whose tests pass perfectly well.
#
# Only THIS signature earns a retry, and only one. A blanket retry would double the time of every
# genuinely failing run and hide the failures it was meant to surface.
if ! grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG" \
   && grep -q "module file .*\.pcm' not found" "$LOG"; then
  echo "→ the module cache in $DD was pruned from under the build — discarding it and building once more"
  rm -rf "$DD"
  run_tests
  rc=$?
fi

# Report what actually happened, in the words xcodebuild used. Compiler errors only —
# a test host logs plenty of "error: Error Domain=…" chatter that is not a failure.
grep -E "[0-9]+:[0-9]+: error:" "$LOG" | sed 's|.*/Night Shift/||' | sort -u | head -20
tests_line="$(grep -E "Executed [0-9]+ test" "$LOG" | tail -1 | sed 's/^[[:space:]]*//')"
[ -n "$tests_line" ] && echo "$tests_line"

if grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"; then
  echo "verified: build + tests pass"
  rm -f "$LOG"
  exit 0
fi

# Distinguish "the tests failed" from "the run never got that far" — an unattended reader
# needs to know which, and a silent non-zero tells them nothing.
if grep -q "Testing cancelled because the build failed" "$LOG"; then
  # xcodebuild calls this TEST FAILED, which is the one thing it is not: nothing ran.
  echo "FAILED: the build did not compile — no test ever ran"
elif grep -q "\*\* TEST FAILED \*\*" "$LOG"; then
  echo "FAILED: tests ran and did not pass"
elif grep -q "\*\* BUILD FAILED \*\*" "$LOG"; then
  echo "FAILED: the build did not compile"
else
  echo "FAILED: xcodebuild exited $rc without a verdict — last lines follow"
  tail -25 "$LOG"
fi
echo "full log: $LOG"
exit 1
