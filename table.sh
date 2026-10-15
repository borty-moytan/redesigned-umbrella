# Aligned table formatter for CSV and delimiter-separated text.
# Examples: f_table data.csv; cat data.tsv | f_table --sep '\\t'; f_table data.txt '|'

f_table() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$F_HOME/helpers/table_tool.py" "$@"
    return $?
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    python "$F_HOME/helpers/table_tool.py" "$@"
    return $?
  fi
  printf 'f_table: Python 3 is required for robust CSV quoting and display-width handling.\n' >&2
  return 127
}
