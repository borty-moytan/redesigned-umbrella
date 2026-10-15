#!/usr/bin/env bash
# F Bash toolkit: source this file from ~/.bashrc.
# This file intentionally does not change shell options or install global traps.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'F: source this file from Bash; do not execute it directly.\n' >&2
  exit 1
fi

# Keep the installation root tied to this setup.sh, even when the user sources
# another copy later in the same shell. Nested modules do not rewrite F_HOME.
F_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
  printf 'F: could not determine the setup directory.\n' >&2
  return 1
}

# Source eligible .sh files directly inside a directory. The caller may supply
# one setup file to exclude (normally the setup file currently being executed).
__f_source_dir_scripts() {
  local _f_dir _f_exclude _f_script _f_basename
  _f_dir="${1:-}"
  _f_exclude="${2:-}"
  [[ -n "$_f_dir" && -d "$_f_dir" ]] || return 2

  for _f_script in "$_f_dir"/*.sh "$_f_dir"/.[!.]*.sh "$_f_dir"/..?*.sh; do
    [[ -f "$_f_script" ]] || continue
    [[ -n "$_f_exclude" && "$_f_script" == "$_f_exclude" ]] && continue
    _f_basename="${_f_script##*/}"
    # An underscore prefix marks a shell script as intentionally not auto-loaded.
    [[ "$_f_basename" == _* ]] && continue
    if ! source "$_f_script"; then
      printf 'F setup: failed to source script: %s\n' "$_f_script" >&2
    fi
  done
}

# Walk a directory encountered beneath a module:
#   * if it has setup.sh, source only that file and stop walking this branch;
#   * otherwise, source its eligible *.sh files, then walk its child folders.
# A setup.sh can explicitly call __f_load_module_dir if it wants to manage its
# own module directory and descendants. Directories are canonicalized to avoid
# recursive loops through symlinks.
__f_walk_dir() {
  local _f_dir _f_child _f_setup _f_dir_name
  _f_dir="${1:-}"
  [[ -n "$_f_dir" ]] || return 2

  # Check the discovered path's name before canonicalizing it. This also skips
  # underscore-prefixed symlink names, even if their targets have another name.
  _f_dir_name="${_f_dir%/}"
  _f_dir_name="${_f_dir_name##*/}"
  [[ "$_f_dir_name" == _* ]] && return 0

  [[ -d "$_f_dir" ]] || return 2
  _f_dir="$(cd -- "$_f_dir" 2>/dev/null && pwd -P)" || return 2

  # Prevent duplicate traversal and symlink cycles. This marker is intentionally
  # distinct from the module-loaded marker used by __f_load_module_dir.
  local _f_key _f_walk_marker
  _f_key="$(printf '%s' "$_f_dir" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "$_f_key" ]] || _f_key="$(printf '%s' "$_f_dir" | wc -c | tr -d ' ')"
  _f_walk_marker="__F_WALK_SEEN_${_f_key}"
  [[ "${!_f_walk_marker:-}" == 1 ]] && return 0
  printf -v "$_f_walk_marker" '%s' 1

  _f_setup="$_f_dir/setup.sh"
  if [[ -f "$_f_setup" ]]; then
    # setup.sh owns this branch; do not scan beside it or descend further here.
    # If it wants to load its siblings/children, it can explicitly invoke the
    # module loader itself.
    local _f_setup_base="${_f_setup##*/}"
    [[ "$_f_setup_base" == _* ]] && return 0
    if ! source "$_f_setup"; then
      printf 'F setup: failed to load directory setup: %s\n' "$_f_setup" >&2
    fi
    return 0
  fi

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
  [[ -n "$_f_setup_file" ]] || return 2

  # Explicit module loads obey the same directory exclusion as automatic walks.
  _f_input_dir="$(dirname -- "$_f_setup_file")"
  _f_dir_name="${_f_input_dir%/}"
  _f_dir_name="${_f_dir_name##*/}"
  [[ "$_f_dir_name" == _* ]] && return 0

  _f_dir="$(cd -- "$_f_input_dir" 2>/dev/null && pwd -P)" || return 2
  _f_setup_file="$_f_dir/$(basename -- "$_f_setup_file")"

  _f_key="$(printf '%s' "$_f_dir" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "$_f_key" ]] || _f_key="$(printf '%s' "$_f_dir" | wc -c | tr -d ' ')"
  _f_marker="__F_MODULE_LOADED_${_f_key}"
  [[ "${!_f_marker:-}" == 1 ]] && return 0
  printf -v "$_f_marker" '%s' 1

  __f_source_dir_scripts "$_f_dir" "$_f_setup_file" || return $?
  for _f_child in "$_f_dir"/*/ "$_f_dir"/.[!.]*/ "$_f_dir"/..?*/; do
    [[ -d "$_f_child" ]] || continue
    __f_walk_dir "${_f_child%/}"
  done
}

__f_load_module_dir "${BASH_SOURCE[0]}"
