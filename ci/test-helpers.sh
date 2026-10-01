#!/usr/bin/env bash
# test-helpers.sh - tiny assertion helpers shared by ci/test-*.sh.
# Source this file; call finish_tests at the end of the test script.
# It sets ROOT (the repo checkout) and TMP (a temp folder removed on exit; a
# script that sets its own EXIT trap must remove $TMP itself).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEST_FAILURES=0
TEST_PASSES=0

pass() { printf '[PASS] %s\n' "$*"; TEST_PASSES=$((TEST_PASSES + 1)); }
fail() { printf '[FAIL] %s\n' "$*" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
skip() { printf '[SKIP] %s\n' "$*"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

# assert_contains NAME NEEDLE HAYSTACK
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name (expected output to contain '$needle', got: '$haystack')"
    fi
}

# assert_lacks NAME NEEDLE HAYSTACK
assert_lacks() {
    if [[ "$3" == *"$2"* ]]; then fail "$1 (did not expect '$2')"; else pass "$1"; fi
}

# assert_ok NAME CMD [ARGS...]  - command must exit 0 (run in a subshell)
assert_ok() {
    local name="$1"; shift
    if ( "$@" ) >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name (expected exit 0)"
    fi
}

# assert_fails NAME CMD [ARGS...]  - command must exit non-zero (run in a subshell)
assert_fails() {
    local name="$1"; shift
    if ( "$@" ) >/dev/null 2>&1; then
        fail "$name (expected non-zero exit)"
    else
        pass "$name"
    fi
}

# stub_container_helpers - replace the Docker, image and port helpers a
# container task calls before container_up with no-ops (no port is taken).
stub_container_helpers() {
    require_image_ref() { :; }
    container_require_64bit() { :; }
    container_require_docker() { :; }
    container_pull() { :; }
    container_stop_native() { :; }
    container_state() { :; }
    port_owner() { return 1; }
}

finish_tests() {
    echo
    if [[ $TEST_FAILURES -gt 0 ]]; then
        printf '[FAIL] %d assertion(s) failed, %d passed.\n' "$TEST_FAILURES" "$TEST_PASSES" >&2
        exit 1
    fi
    printf '[PASS] All %d assertions passed.\n' "$TEST_PASSES"
}
