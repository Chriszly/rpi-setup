#!/usr/bin/env bash
# test-helpers.sh - tiny assertion helpers shared by ci/test-*.sh.
# Source this file; call finish_tests at the end of the test script.

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

finish_tests() {
    echo
    if [[ $TEST_FAILURES -gt 0 ]]; then
        printf '[FAIL] %d assertion(s) failed, %d passed.\n' "$TEST_FAILURES" "$TEST_PASSES" >&2
        exit 1
    fi
    printf '[PASS] All %d assertions passed.\n' "$TEST_PASSES"
}
