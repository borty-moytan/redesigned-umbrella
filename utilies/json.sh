# JSON helper. Uses Python's standard-library json module, with a Perl JSON::PP
# backup when Python is unavailable. jq is not required.
# Usage: f_json [FILE|-] [DOTTED.PATH [= VALUE]]
# Pipe usage: cat file.json | f_json [DOTTED.PATH [= VALUE]]

f_json() {
  if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
    cat <<'HELP'
Usage: f_json [FILE|-] [DOTTED.PATH [= VALUE]]
       cat FILE.json | f_json [DOTTED.PATH [= VALUE]]

Without a path, prints the full JSON document. A path reads one value;
PATH=VALUE updates a file atomically, creating missing intermediate objects.
Valid JSON values retain their types; other values are stored as strings.
HELP
    return 0
  fi
  local _f_file_arg="${1:-}"
  if (($# == 0)); then
    set -- '-'
  elif [[ "$_f_file_arg" == '-' || -f "$_f_file_arg" || "$_f_file_arg" == */* || "$_f_file_arg" == *.json ]]; then
    : # Explicit file input.
  else
    if [[ -t 0 ]]; then
      printf 'f_json: first argument is not an existing file. Pipe JSON to f_json to use a dotted path without a filename.\n' >&2
      return 2
    fi
    set -- '-' "$@"
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 "$F_HOME/helpers/json_tool.py" "$@"
    return $?
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    python "$F_HOME/helpers/json_tool.py" "$@"
    return $?
  elif command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 'exit 0' >/dev/null 2>&1; then
    perl "$F_HOME/helpers/json_tool.pl" "$@"
    return $?
  fi
  printf 'f_json: neither Python nor Perl is available; no JSON operation was performed.\n' >&2
  return 127
}
