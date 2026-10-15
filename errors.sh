# Structured Bash error logging. The ERR trap is opt-in because installing a
# process-wide trap in an interactive shell would be surprising and intrusive.

__f_error_colors_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]
}

__f_error_trap() {
  local _f_status="${1:-1}" _f_command="${2:-unknown command}"
  local _f_file="${3:-unknown file}" _f_line="${4:-0}"
  local _f_failed_function="${FUNCNAME[1]:-}"
  [[ "$_f_status" =~ ^[0-9]+$ ]] || _f_status=1

  # With `set -E`, Bash may fire ERR once inside a function and again at the
  # top level for the same failure. The second event has no function stack and
  # arrives immediately, so skip that duplicate record.
  if [[ "${__F_ERROR_PENDING_STATUS:-}" == "$_f_status" \
        && "${__F_ERROR_PENDING_COMMAND:-}" == "$_f_command" \
        && "${__F_ERROR_PENDING_SECOND:-}" == "$SECONDS" ]]; then
    # Keep the marker through intermediate callers; clear it at top level.
    if [[ -z "$_f_failed_function" || "$_f_failed_function" == 'main' ]]; then
      unset __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_COMMAND __F_ERROR_PENDING_SECOND
    fi
    return 0
  fi

  __f_render_error_trace "$_f_status" "$_f_command" "$_f_file" "$_f_line"
  if [[ -n "$_f_failed_function" && "$_f_failed_function" != '__f_error_trap' && "$_f_failed_function" != 'main' ]]; then
    __F_ERROR_PENDING_STATUS="$_f_status"
    __F_ERROR_PENDING_COMMAND="$_f_command"
    __F_ERROR_PENDING_SECOND="$SECONDS"
  else
    unset __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_COMMAND __F_ERROR_PENDING_SECOND
  fi
  return 0
}

__f_render_error_trace() {
  local _f_status="${1:-1}" _f_command="${2:-unknown command}"
  local _f_file="${3:-unknown file}" _f_line="${4:-0}"
  local _f_red='' _f_yellow='' _f_cyan='' _f_reset='' _f_bold=''
  local _f_i _f_fn _f_src _f_ln

  if __f_error_colors_enabled; then
    _f_red=$'\033[1;31m'; _f_yellow=$'\033[33m'; _f_cyan=$'\033[36m'
    _f_bold=$'\033[1m'; _f_reset=$'\033[0m'
  fi

  printf '\n%sTraceback (most recent call last):%s\n' "$_f_bold" "$_f_reset" >&2
  # The failing location is explicit; the stack frames below show callers.
  printf '  File "%s", line %s, in %s\n' "$_f_file" "$_f_line" "${FUNCNAME[2]:-<module>}" >&2
  for ((_f_i=3; _f_i<${#FUNCNAME[@]}; _f_i++)); do
    _f_fn="${FUNCNAME[$_f_i]:-<module>}"
    _f_src="${BASH_SOURCE[$_f_i]:-$_f_file}"
    _f_ln="${BASH_LINENO[$((_f_i-1))]:-$_f_line}"
    [[ "$_f_fn" == '__f_error_trap' || "$_f_fn" == '__f_render_error_trace' ]] && continue
    [[ "$_f_src" == */errors.sh ]] && continue
    printf '  File "%s", line %s, in %s\n' "$_f_src" "$_f_ln" "$_f_fn" >&2
  done
  printf '%sFError%s: command failed with exit status %s\n' "$_f_red" "$_f_reset" "$_f_status" >&2
  printf '  %sCommand:%s %s%s%s\n\n' "$_f_yellow" "$_f_reset" "$_f_cyan" "$_f_command" "$_f_reset" >&2
  return 0
}

# Usage: f_log_error [EXIT_STATUS] [COMMAND_OR_CONTEXT]
f_log_error() {
  local _f_status=1 _f_message='manual error'
  if (($# > 0)); then _f_status="$1"; shift; fi
  if (($# > 0)); then _f_message="$*"; fi
  local _f_caller="${BASH_SOURCE[1]:-}"
  if [[ -z "$_f_caller" || "$_f_caller" == "${BASH_SOURCE[0]:-}" ]]; then
    _f_caller="${BASH_SOURCE[2]:-<interactive shell>}"
  fi
  __f_render_error_trace "$_f_status" "$_f_message" "$_f_caller" "${BASH_LINENO[0]:-0}"
}

# Usage: f_enable_error_trap [--inherit]
# --inherit enables Bash's errtrace option so the ERR trap also propagates into
# functions/subshell contexts. That option is not enabled unless requested.
f_enable_error_trap() {
  local _f_inherit=0
  [[ "${1:-}" == '--inherit' ]] && _f_inherit=1
  if [[ "${__F_ERROR_TRAP_ACTIVE:-0}" == 1 ]]; then
    printf 'F: the error trap is already enabled.\n' >&2
    return 0
  fi
  __F_ERROR_TRAP_PREVIOUS="$(trap -p ERR)"
  __F_ERROR_TRAP_WAS_ERRTRACE=0
  if [[ -o errtrace ]]; then __F_ERROR_TRAP_WAS_ERRTRACE=1; fi
  if ((_f_inherit)) && [[ "$__F_ERROR_TRAP_WAS_ERRTRACE" == 0 ]]; then
    set -E
    __F_ERROR_TRAP_ADDED_ERRTRACE=1
  else
    __F_ERROR_TRAP_ADDED_ERRTRACE=0
  fi
  trap '__f_error_trap "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]:-unknown}" "$LINENO"' ERR
  __F_ERROR_TRAP_ACTIVE=1
}

f_disable_error_trap() {
  [[ "${__F_ERROR_TRAP_ACTIVE:-0}" == 1 ]] || return 0
  trap - ERR
  if [[ -n "${__F_ERROR_TRAP_PREVIOUS:-}" ]]; then
    # trap -p produces shell-quoted Bash syntax for the user's existing trap.
    eval "$__F_ERROR_TRAP_PREVIOUS"
  fi
  if [[ "${__F_ERROR_TRAP_ADDED_ERRTRACE:-0}" == 1 ]]; then set +E; fi
  unset __F_ERROR_TRAP_PREVIOUS __F_ERROR_TRAP_ACTIVE __F_ERROR_TRAP_WAS_ERRTRACE __F_ERROR_TRAP_ADDED_ERRTRACE __F_ERROR_LOGGED_FUNCTION __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_COMMAND __F_ERROR_PENDING_SECOND
}
