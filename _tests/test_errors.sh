#!/usr/bin/env bash
set -u
F_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../errors.sh
source "$F_HOME/errors.sh"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# A failed command and its propagated return should generate exactly one report.
if bash -c '
  source "$1/errors.sh"
  f_enable_error_trap --inherit
  fail_once() {
    ls __F_TEST_FILE_THAT_DOES_NOT_EXIST__ >/dev/null
    local errsv=$?
    return "$errsv"
  }
  fail_once
' _ "$F_HOME" >"$out" 2>&1; then
  printf 'FAIL: test command unexpectedly returned success\n' >&2
  exit 1
fi

count="$(grep -c '^FError:' "$out" || true)"
if [[ "$count" != 1 ]]; then
  printf 'FAIL: expected one FError record, got %s\n' "$count" >&2
  cat "$out" >&2
  exit 1
fi
grep -Fq 'Command  : ls __F_TEST_FILE_THAT_DOES_NOT_EXIST__' "$out" || {
  printf 'FAIL: original failed command missing from log\n' >&2; cat "$out" >&2; exit 1;
}
grep -Fq 'File "' "$out" || { printf 'FAIL: file frame missing\n' >&2; cat "$out" >&2; exit 1; }
grep -Fq 'Directory:' "$out" || { printf 'FAIL: directory metadata missing\n' >&2; cat "$out" >&2; exit 1; }
if grep -Fq 'Command  : return' "$out"; then
  printf 'FAIL: propagated return was logged as root cause\n' >&2
  cat "$out" >&2
  exit 1
fi

# A later, independent failure with the same status must not be suppressed.
if bash -c '
  source "$1/errors.sh"
  f_enable_error_trap --inherit
  fail_but_return_success() {
    ls __F_TEST_FILE_THAT_DOES_NOT_EXIST__ >/dev/null
    local errsv=$?
    return 0
  }
  fail_but_return_success
  false
' _ "$F_HOME" >"$out" 2>&1; then
  printf 'FAIL: independent-failure test unexpectedly returned success\n' >&2
  exit 1
fi
count="$(grep -c '^FError:' "$out" || true)"
if [[ "$count" != 2 ]]; then
  printf 'FAIL: expected two distinct failures to be logged, got %s\n' "$count" >&2
  cat "$out" >&2
  exit 1
fi
grep -Fq 'Command  : false' "$out" || {
  printf 'FAIL: independent later failure was hidden\n' >&2; cat "$out" >&2; exit 1;
}

printf 'PASS: error logger preserves original command and traceback, suppresses only propagated returns, and retains independent failures\n'
