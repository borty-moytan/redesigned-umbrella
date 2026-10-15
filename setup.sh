#!/usr/bin/env bash
# F Bash toolkit: source this file from ~/.bashrc.
# Usage: source /path/to/F/setup.sh [-v|--verbose]
# This file intentionally does not change shell options or install global traps.

# Pass -v/--verbose to the `source` command to see loader decisions and outcomes.
# The value persists in the current shell so later explicit module loads are verbose too.
__F_VERBOSE=0
__f_verbose_option_seen=0
for __f_setup_arg in "$@"; do
  case "$__f_setup_arg" in
    -v|--verbose)
      __F_VERBOSE=1
      __f_verbose_option_seen=1
      ;;
  esac
done
# `source file --verbose` temporarily replaces positional parameters. Clear the
# source arguments while loading nested files, so modules do not accidentally
# inherit --verbose as their own $1; Bash restores the caller's parameters when
# the top-level source command returns.
if [[ "$__f_verbose_option_seen" == 1 ]]; then
  set --
fi
unset __f_setup_arg __f_verbose_option_seen

# One consistent, readable log format. Normal informational messages are quiet
# unless verbose mode is enabled; warnings and errors are always visible.
__f_log() {
  local _f_level="${1:-INFO}" _f_message _f_time _f_color='' _f_reset='' _f_symbol
  shift || true
  _f_message="$*"

  if [[ "${__F_VERBOSE:-0}" != 1 && "$_f_level" != WARN && "$_f_level" != ERROR ]]; then
    return 0
  fi

  _f_time="$(date '+%H:%M:%S' 2>/dev/null)" || _f_time='--:--:--'
  case "$_f_level" in
    START)    _f_symbol='▶'; _f_color=$'\033[1;36m' ;;
    INFO)     _f_symbol='•'; _f_color=$'\033[36m' ;;
    TRACE)    _f_symbol='↳'; _f_color=$'\033[2m' ;;
    OK)       _f_symbol='✓'; _f_color=$'\033[32m' ;;
    SKIP)     _f_symbol='↷'; _f_color=$'\033[33m' ;;
    BOUNDARY) _f_symbol='▣'; _f_color=$'\033[35m' ;;
    SUMMARY)  _f_symbol='◆'; _f_color=$'\033[1;32m' ;;
    WARN)     _f_symbol='!'; _f_color=$'\033[1;33m' ;;
    ERROR)    _f_symbol='✗'; _f_color=$'\033[1;31m' ;;
    *)        _f_symbol='•'; _f_color=$'\033[36m' ;;
  esac

  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
    _f_reset=$'\033[0m'
  else
    _f_color=''
  fi
  printf '%s[F %s] %s %-7s%s %s\n' \
    "$_f_color" "$_f_time" "$_f_symbol" "$_f_level" "$_f_reset" "$_f_message" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'F: source this file from Bash; do not execute it directly.\n' >&2
  exit 1
fi

# Keep the installation root tied to this setup.sh, even when the user sources
# another copy later in the same shell. Nested modules do not rewrite F_HOME.
F_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
  __f_log ERROR 'Could not determine the setup directory.'
  return 1
}

# Verbose counters summarise what happened during this load pass.
__F_LOADER_LOADED=0
__F_LOADER_SKIPPED=0
__F_LOADER_DIRS=0
__F_LOADER_FAILURES=0

# Source eligible .sh files directly inside a directory. The caller may supply
# one setup file to exclude (normally the setup file currently being executed).
__f_source_dir_scripts() {
  local _f_dir _f_exclude _f_script _f_basename _f_found=0 _f_status
  _f_dir="${1:-}"
  _f_exclude="${2:-}"
  [[ -n "$_f_dir" && -d "$_f_dir" ]] || return 2

  __f_log TRACE "Scanning shell scripts in: $_f_dir"
  for _f_script in "$_f_dir"/*.sh "$_f_dir"/.[!.]*.sh "$_f_dir"/..?*.sh; do
    [[ -f "$_f_script" ]] || continue
    [[ -n "$_f_exclude" && "$_f_script" == "$_f_exclude" ]] && continue
    _f_basename="${_f_script##*/}"
    # An underscore prefix marks a shell script as intentionally not auto-loaded.
    if [[ "$_f_basename" == _* ]]; then
      __F_LOADER_SKIPPED=$((__F_LOADER_SKIPPED + 1))
      __f_log SKIP "Underscore-prefixed script ignored: $_f_script"
      continue
    fi

    _f_found=1
    __f_log TRACE "Sourcing script: $_f_script"
    if source "$_f_script"; then
      __F_LOADER_LOADED=$((__F_LOADER_LOADED + 1))
      __f_log OK "Loaded script: $_f_script"
    else
      _f_status=$?
      __F_LOADER_FAILURES=$((__F_LOADER_FAILURES + 1))
      __f_log ERROR "Failed to source script (status $_f_status): $_f_script"
    fi
  done
  [[ "$_f_found" == 1 ]] || __f_log TRACE "No eligible .sh scripts found in: $_f_dir"
}

# Walk a directory encountered beneath a module:
#   * if it has setup.sh, source only that file and stop walking this branch;
#   * otherwise, source its eligible *.sh files, then walk its child folders.
# A setup.sh can explicitly call __f_load_module_dir if it wants to manage its
# own module directory and descendants. Directories are canonicalized to avoid
# recursive loops through symlinks.
__f_walk_dir() {
  local _f_dir _f_child _f_setup _f_dir_name _f_key _f_walk_marker _f_status
  _f_dir="${1:-}"
  [[ -n "$_f_dir" ]] || return 2

  # Check the discovered path's name before canonicalizing it. This also skips
  # underscore-prefixed symlink names, even if their targets have another name.
  _f_dir_name="${_f_dir%/}"
  _f_dir_name="${_f_dir_name##*/}"
  if [[ "$_f_dir_name" == _* ]]; then
    __F_LOADER_SKIPPED=$((__F_LOADER_SKIPPED + 1))
    __f_log SKIP "Underscore-prefixed directory ignored entirely: $_f_dir"
    return 0
  fi

  [[ -d "$_f_dir" ]] || return 2
  _f_dir="$(cd -- "$_f_dir" 2>/dev/null && pwd -P)" || {
    __f_log WARN "Could not resolve directory path: ${1:-}"
    return 2
  }

  # Prevent duplicate traversal and symlink cycles. This marker is intentionally
  # distinct from the module-loaded marker used by __f_load_module_dir.
  _f_key="$(printf '%s' "$_f_dir" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "$_f_key" ]] || _f_key="$(printf '%s' "$_f_dir" | wc -c | tr -d ' ')"
  _f_walk_marker="__F_WALK_SEEN_${_f_key}"
  if [[ "${!_f_walk_marker:-}" == 1 ]]; then
    __F_LOADER_SKIPPED=$((__F_LOADER_SKIPPED + 1))
    __f_log SKIP "Directory already visited; avoiding duplicate traversal: $_f_dir"
    return 0
  fi
  printf -v "$_f_walk_marker" '%s' 1

  __F_LOADER_DIRS=$((__F_LOADER_DIRS + 1))
  __f_log TRACE "Inspecting directory: $_f_dir"
  _f_setup="$_f_dir/setup.sh"
  if [[ -f "$_f_setup" ]]; then
    # setup.sh owns this branch; do not scan beside it or descend further here.
    __f_log BOUNDARY "Found setup.sh; loading it as this branch's entry point: $_f_setup"
    __f_log TRACE "Sibling scripts and child directories will not be auto-loaded from this branch."
    if source "$_f_setup"; then
      __F_LOADER_LOADED=$((__F_LOADER_LOADED + 1))
      __f_log OK "Loaded directory setup: $_f_setup"
    else
      _f_status=$?
      __F_LOADER_FAILURES=$((__F_LOADER_FAILURES + 1))
      __f_log ERROR "Failed to load directory setup (status $_f_status): $_f_setup"
    fi
    return 0
  fi

  __f_log TRACE "No setup.sh found; loading local scripts and then exploring child directories: $_f_dir"
  __f_source_dir_scripts "$_f_dir" || return $?
  for _f_child in "$_f_dir"/*/ "$_f_dir"/.[!.]*/ "$_f_dir"/..?*/; do
    [[ -d "$_f_child" ]] || continue
    __f_walk_dir "${_f_child%/}"
  done
}

# Load a module directory identified by its setup.sh. This is an explicit opt-in
# from that setup file: load the other local scripts, then apply the walking rule
# to every child directory. A child with setup.sh gets only that file sourced;
# a child without it gets its scripts loaded and its subtree traversed.
__f_load_module_dir() {
  local _f_setup_file _f_dir _f_child _f_key _f_marker _f_dir_name _f_input_dir
  _f_setup_file="${1:-}"
  [[ -n "$_f_setup_file" ]] || {
    __f_log WARN 'Module load requested without a setup file path.'
    return 2
  }

  # Explicit module loads obey the same directory exclusion as automatic walks.
  _f_input_dir="$(dirname -- "$_f_setup_file")"
  _f_dir_name="${_f_input_dir%/}"
  _f_dir_name="${_f_dir_name##*/}"
  if [[ "$_f_dir_name" == _* ]]; then
    __F_LOADER_SKIPPED=$((__F_LOADER_SKIPPED + 1))
    __f_log SKIP "Explicit module load ignored because its directory starts with _: $_f_input_dir"
    return 0
  fi

  _f_dir="$(cd -- "$_f_input_dir" 2>/dev/null && pwd -P)" || {
    __f_log WARN "Could not resolve module directory: $_f_input_dir"
    return 2
  }
  _f_setup_file="$_f_dir/$(basename -- "$_f_setup_file")"
  __f_log TRACE "Module load requested: directory=$_f_dir entry=$_f_setup_file"

  _f_key="$(printf '%s' "$_f_dir" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "$_f_key" ]] || _f_key="$(printf '%s' "$_f_dir" | wc -c | tr -d ' ')"
  _f_marker="__F_MODULE_LOADED_${_f_key}"
  if [[ "${!_f_marker:-}" == 1 ]]; then
    __F_LOADER_SKIPPED=$((__F_LOADER_SKIPPED + 1))
    __f_log SKIP "Module already initialized; skipping duplicate load: $_f_dir"
    return 0
  fi
  printf -v "$_f_marker" '%s' 1

  __f_source_dir_scripts "$_f_dir" "$_f_setup_file" || return $?
  __f_log TRACE "Exploring child directories of module: $_f_dir"
  for _f_child in "$_f_dir"/*/ "$_f_dir"/.[!.]*/ "$_f_dir"/..?*/; do
    [[ -d "$_f_child" ]] || continue
    __f_walk_dir "${_f_child%/}"
  done
}

__f_log START "Initializing Bash toolkit from: $F_HOME"
if __f_load_module_dir "${BASH_SOURCE[0]}"; then
  __f_log SUMMARY "Load pass complete: ${__F_LOADER_LOADED} scripts/setups loaded, ${__F_LOADER_SKIPPED} entries skipped, ${__F_LOADER_DIRS} directories inspected, ${__F_LOADER_FAILURES} load failures."
else
  __f_load_status=$?
  __f_log ERROR "Loader stopped with status $__f_load_status."
  return "$__f_load_status"
fi
