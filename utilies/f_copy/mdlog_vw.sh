#!/usr/bin/env bash
# Friendly JSON history viewer and guarded historical-command replay.

mdlog_vw() {
  if [[ ! -r "${__F_COPY_TOOL:-}" ]]; then
    printf '[f_copy] ERROR: mdlog helper is unavailable. Re-source F/setup.sh.\n' >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[f_copy] ERROR: mdlog_vw requires Python 3 (standard library only).\n' >&2
    return 127
  fi
  command python3 "$__F_COPY_TOOL" view "$@"
}
