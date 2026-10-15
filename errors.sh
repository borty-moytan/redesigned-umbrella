# Structured Bash error logging. The ERR trap is opt-in because installing a
# process-wide trap in an interactive shell would be surprising and intrusive.

__f_error_colors_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]
}

__f_error_trap() {
  local _f_status="${1:-1}" _f_command="${2:-unknown command}"
  local _f_file="${3:-unknown file}" _f_line="${4:-0}"
  local _f_failed_function="${5:-main}"
  [[ "$_f_status" =~ ^[0-9]+$ ]] || _f_status=1

  # Copy these arrays directly inside the handler, before calling the renderer;
  # helper-function capture would add a bogus frame to the traceback.
  __F_ERROR_TRACE_FUNCTIONS=("${FUNCNAME[@]:1}")
  __F_ERROR_TRACE_SOURCES=("${BASH_SOURCE[@]:1}")
  __F_ERROR_TRACE_CALL_LINES=("${BASH_LINENO[@]}")

  # Bash can raise ERR for the original failing command, and again when that
  # status is propagated out of a function. Once the function frame has gone,
  # BASH_COMMAND may misleadingly say `return "$status"` and the source location
  # may be unavailable. Suppress a same-status event in a caller only when Bash
  # reports the original command again or an explicit return. This avoids hiding
  # a later, unrelated failure with the same exit status.
  if [[ -n "${__F_ERROR_PENDING_STATUS:-}" ]]; then
    if [[ "$_f_status" == "$__F_ERROR_PENDING_STATUS" \
       && "$_f_failed_function" != "${__F_ERROR_PENDING_FUNCTION:-}" \
       && ( "$_f_command" == "${__F_ERROR_PENDING_COMMAND:-}" \
            || "$_f_command" =~ ^[[:space:]]*return([[:space:]]|$) ) ]]; then
      if [[ "$_f_failed_function" != main ]]; then
        __F_ERROR_PENDING_FUNCTION="$_f_failed_function"
      else
        unset __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_FUNCTION __F_ERROR_PENDING_COMMAND
      fi
      return 0
    fi
    unset __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_FUNCTION __F_ERROR_PENDING_COMMAND
  fi

  __f_render_error_trace "$_f_status" "$_f_command" "$_f_file" "$_f_line" "$_f_failed_function"

  # Remember function-local failures in case Bash reports their propagated
  # status again after the function frame has unwound.
  if [[ "$_f_failed_function" != main ]]; then
    __F_ERROR_PENDING_STATUS="$_f_status"
    __F_ERROR_PENDING_FUNCTION="$_f_failed_function"
    __F_ERROR_PENDING_COMMAND="$_f_command"
  else
    unset __F_ERROR_PENDING_STATUS __F_ERROR_PENDING_FUNCTION __F_ERROR_PENDING_COMMAND
  fi
  return 0
}

__f_render_error_trace() {
  local _f_status="${1:-1}" _f_command="${2:-unknown command}"
  local _f_file="${3:-unknown file}" _f_line="${4:-0}"
  local _f_failed_function="${5:-main}"
  local _f_red='' _f_yellow='' _f_cyan='' _f_reset='' _f_bold=''
  local _f_i _f_fn _f_src _f_ln

  if __f_error_colors_enabled; then
    _f_red=$'\033[1;31m'; _f_yellow=$'\033[33m'; _f_cyan=$'\033[36m'
    _f_bold=$'\033[1m'; _f_reset=$'\033[0m'
  fi

  printf '\n%sTraceback (most recent call last):%s\n' "$_f_bold" "$_f_reset" >&2
  printf '  File "%s", line %s, in %s\n' "$_f_file" "$_f_line" "$_f_failed_function" >&2

  # Frame arrays were copied in the ERR handler before entering this renderer.
  # Index 0 is the failing context; higher indices are its callers.
  for ((_f_i=1; _f_i<${#__F_ERROR_TRACE_FUNCTIONS[@]}; _f_i++)); do
    _f_fn="${__F_ERROR_TRACE_FUNCTIONS[$_f_i]:-main}"
    _f_src="${__F_ERROR_TRACE_SOURCES[$_f_i]:-$_f_file}"
    _f_ln="${__F_ERROR_TRACE_CALL_LINES[$_f_i]:-0}"
    [[ -n "$_f_src" ]] || _f_src="$_f_file"
    [[ "$_f_fn" == '__f_error_trap' || "$_f_fn" == '__f_render_error_trace' ]] && continue
    [[ "$_f_src" == */errors.sh ]] && continue
    [[ "$_f_src" == "$_f_file" && "$_f_ln" == "$_f_line" && "$_f_fn" == "$_f_failed_function" ]] && continue
    [[ "$_f_fn" == main && "$_f_src" == "$_f_file" && "$_f_ln" == "$_f_line" ]] && continue
    printf '  File "%s", line %s, in %s\n' "$_f_src" "$_f_ln" "$_f_fn" >&2
  done

  printf '%sFError%s: command failed with exit status %s\n' "$_f_red" "$_f_reset" "$_f_status" >&2
  printf '  %sCommand  :%s %s%s%s\n' "$_f_yellow" "$_f_reset" "$_f_cyan" "$_f_command" "$_f_reset" >&2
  printf '  Location : %s:%s' "$_f_file" "$_f_line" >&2
  [[ -n "$_f_failed_function" ]] && printf ' (in %s)' "$_f_failed_function" >&2
  printf '\n  Directory: %s\n  Shell    : Bash %s\n  PID      : %s\n\n' \
    "$PWD" "${BASH_VERSION:-unknown}" "$$" >&2
  return 0
}

# Usage: f_log_error [EXIT_STATUS] [MESSAGE_OR_COMMAND]
# Emits a traceback-style record for a deliberately logged error.
f_log_error() {
  local _f_status=1 _f_message='manual error' _f_caller _f_line _f_function
  if (($# > 0)); then _f_status="$1"; shift; fi
  if (($# > 0)); then _f_message="$*"; fi
  _f_caller="${BASH_SOURCE[1]:-<interactive shell>}"
  _f_line="${BASH_LINENO[0]:-0}"
  _f_function="${FUNCNAME[1]:-main}"
  __F_ERROR_TRACE_FUNCTIONS=("$_f_function")
  __F_ERROR_TRACE_SOURCES=("$_f_caller")
  __F_ERROR_TRACE_CALL_LINES=("$_f_line")
  __f_render_error_trace "$_f_status" "$_f_message" "$_f_caller" "$_f_line" "$_f_function"
}

# Usage: f_enable_error_trap [--inherit]
# --inherit enables Bash's errtrace option so ERR also propagates into functions.
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
  trap '__f_error_trap "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]:-unknown file}" "$LINENO" "${FUNCNAME[0]:-main}"' ERR
  __F_ERROR_TRAP_ACTIVE=1
}

f_disable_error_trap() {
  [[ "${__F_ERROR_TRAP_ACTIVE:-0}" == 1 ]] || return 0
  trap - ERR
  if [[ -n "${__F_ERROR_TRAP_PREVIOUS:-}" ]]; then
    # trap -p produces shell-quoted Bash syntax for the user's previous trap.
    eval "$__F_ERROR_TRAP_PREVIOUS"
  fi
  if [[ "${__F_ERROR_TRAP_ADDED_ERRTRACE:-0}" == 1 ]]; then set +E; fi
  unset __F_ERROR_TRAP_PREVIOUS __F_ERROR_TRAP_ACTIVE __F_ERROR_TRAP_WAS_ERRTRACE \
    __F_ERROR_TRAP_ADDED_ERRTRACE __F_ERROR_PENDING_STATUS \
    __F_ERROR_PENDING_FUNCTION __F_ERROR_PENDING_COMMAND __F_ERROR_TRACE_FUNCTIONS __F_ERROR_TRACE_SOURCES __F_ERROR_TRACE_CALL_LINES
}
