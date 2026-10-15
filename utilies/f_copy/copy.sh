#!/usr/bin/env bash
# Logged wrappers around cp and rsync. The underlying command's status is kept.

__f_copy_record_success() {
  local _f_copy_kind="${1:-}" _f_copy_cwd="${2:-}" _f_copy_status
  shift 2 2>/dev/null || return 0

  if [[ -z "$_f_copy_kind" || -z "$_f_copy_cwd" || ! -r "${__F_COPY_TOOL:-}" ]]; then
    printf '[f_copy] WARN: Copy succeeded, but history logging is unavailable (helper missing).\n' >&2
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[f_copy] WARN: Copy succeeded, but history logging needs Python 3. No log was written.\n' >&2
    return 0
  fi

  command python3 "$__F_COPY_TOOL" append "$_f_copy_kind" "$_f_copy_cwd" "$@"
  _f_copy_status=$?
  if (( _f_copy_status != 0 )); then
    printf '[f_copy] WARN: The copy command succeeded, but its history entry could not be saved.\n' >&2
  fi
  # Logging is best-effort and must never replace cp/rsync's exit status.
  return 0
}

f_cp() {
  local _f_copy_status _f_copy_cwd="${PWD:-$(pwd)}"
  command cp "$@"
  _f_copy_status=$?
  if (( _f_copy_status == 0 )); then
    __f_copy_record_success cp "$_f_copy_cwd" "$@"
  fi
  return "$_f_copy_status"
}

f_rsync() {
  local _f_copy_status _f_copy_cwd="${PWD:-$(pwd)}"
  command rsync "$@"
  _f_copy_status=$?
  if (( _f_copy_status == 0 )); then
    __f_copy_record_success rsync "$_f_copy_cwd" "$@"
  fi
  return "$_f_copy_status"
}
