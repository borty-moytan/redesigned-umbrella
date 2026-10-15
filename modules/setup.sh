# Example module collection. New subfolders with setup.sh are discovered recursively.
if declare -F __f_load_module_dir >/dev/null 2>&1; then
  __f_load_module_dir "${BASH_SOURCE[0]}"
else
  printf 'F module: source %s/setup.sh first to initialize the module loader.\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" >&2
fi
