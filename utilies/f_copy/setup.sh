#!/usr/bin/env bash
# f_copy module entry point. Loaded by F/setup.sh, or usable standalone.

__F_COPY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
  printf '[f_copy] ERROR: Could not resolve module directory.\n' >&2
  return 1 2>/dev/null || exit 1
}
__F_COPY_TOOL="$__F_COPY_DIR/mdlog_tool.py"

if declare -F __f_load_module_dir >/dev/null 2>&1; then
  # Opt into loading this module's sibling .sh utilities. The parent loader
  # treats setup.sh as a branch boundary unless this explicit call is made.
  __f_load_module_dir "${BASH_SOURCE[0]}"
else
  # Standalone fallback: load eligible scripts directly in this folder.
  for __f_copy_script in "$__F_COPY_DIR"/*.sh "$__F_COPY_DIR"/.[!.]*.sh "$__F_COPY_DIR"/..?*.sh; do
    [[ -f "$__f_copy_script" ]] || continue
    [[ "${__f_copy_script##*/}" == setup.sh || "${__f_copy_script##*/}" == _* ]] && continue
    source "$__f_copy_script" || {
      printf '[f_copy] ERROR: Failed to source %s\n' "$__f_copy_script" >&2
      return 1 2>/dev/null || exit 1
    }
  done
fi

unset __f_copy_script
