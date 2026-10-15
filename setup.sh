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

# Source a directory as a module tree. The directory is identified by the path to
# its setup.sh. Its other *.sh files are sourced first, then child directories
# which have their own setup.sh are visited recursively.
__f_load_module_dir() {
  local _f_setup_file _f_dir _f_script _f_child _f_key _f_marker
  _f_setup_file="${1:-}"
  [[ -n "$_f_setup_file" ]] || return 2
  _f_dir="$(cd -- "$(dirname -- "$_f_setup_file")" 2>/dev/null && pwd -P)" || return 2
  _f_setup_file="$_f_dir/$(basename -- "$_f_setup_file")"

  # A path-hash marker avoids repeated loading without requiring Bash 4 arrays.
  _f_key="$(printf '%s' "$_f_dir" | cksum 2>/dev/null | awk '{print $1}')"
  [[ -n "$_f_key" ]] || _f_key="$(printf '%s' "$_f_dir" | wc -c | tr -d ' ')"
  _f_marker="__F_MODULE_LOADED_${_f_key}"
  if [[ "${!_f_marker:-}" == 1 ]]; then
    return 0
  fi
  printf -v "$_f_marker" '%s' 1

  # Normal and dot-prefixed shell files, in predictable shell glob order.
  for _f_script in "$_f_dir"/*.sh "$_f_dir"/.[!.]*.sh "$_f_dir"/..?*.sh; do
    [[ -f "$_f_script" ]] || continue
    [[ "$_f_script" == "$_f_setup_file" ]] && continue
    if ! source "$_f_script"; then
      printf 'F setup: failed to source module file: %s\n' "$_f_script" >&2
    fi
  done

  # A folder becomes a module when it contains setup.sh. No arbitrary folders
  # (for example helpers/) are sourced by accident.
  for _f_child in "$_f_dir"/*/ "$_f_dir"/.[!.]*/ "$_f_dir"/..?*/; do
    [[ -d "$_f_child" ]] || continue
    _f_child="${_f_child%/}"
    [[ -f "$_f_child/setup.sh" ]] || continue
    if ! source "$_f_child/setup.sh"; then
      printf 'F setup: failed to load module: %s\n' "$_f_child/setup.sh" >&2
    fi
  done
}

__f_load_module_dir "${BASH_SOURCE[0]}"
