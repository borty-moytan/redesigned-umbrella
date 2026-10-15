# Example leaf module. Copy this folder to create an independent module.
if declare -F __f_load_module_dir >/dev/null 2>&1; then
  __f_load_module_dir "${BASH_SOURCE[0]}"
fi
