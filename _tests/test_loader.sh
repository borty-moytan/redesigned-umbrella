#!/usr/bin/env bash
set -u

F_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Build a miniature tree to assert setup-boundary and no-setup recursion rules.
cp "$F_HOME/setup.sh" "$tmp/setup.sh"
cat > "$tmp/root_loaded.sh" <<'SCRIPT'
F_TEST_ROOT_NORMAL=1
SCRIPT
cat > "$tmp/_root_ignored.sh" <<'SCRIPT'
F_TEST_ROOT_UNDERSCORE=1
SCRIPT

# Underscore-prefixed directories are entirely excluded, even if they contain
# setup.sh, normal scripts, and deeper folders.
mkdir -p "$tmp/_root_ignored_dir/nested" "$tmp/plain/_nested_ignored/nested"
cat > "$tmp/_root_ignored_dir/setup.sh" <<'SCRIPT'
F_TEST_ROOT_UNDERSCORE_DIR_SETUP=1
SCRIPT
cat > "$tmp/_root_ignored_dir/should_not_load.sh" <<'SCRIPT'
F_TEST_ROOT_UNDERSCORE_DIR_SCRIPT=1
SCRIPT
cat > "$tmp/_root_ignored_dir/nested/deeper_should_not_load.sh" <<'SCRIPT'
F_TEST_ROOT_UNDERSCORE_DIR_NESTED=1
SCRIPT
cat > "$tmp/plain/_nested_ignored/setup.sh" <<'SCRIPT'
F_TEST_NESTED_UNDERSCORE_DIR_SETUP=1
SCRIPT
cat > "$tmp/plain/_nested_ignored/should_not_load.sh" <<'SCRIPT'
F_TEST_NESTED_UNDERSCORE_DIR_SCRIPT=1
SCRIPT
cat > "$tmp/plain/_nested_ignored/nested/deeper_should_not_load.sh" <<'SCRIPT'
F_TEST_NESTED_UNDERSCORE_DIR_NESTED=1
SCRIPT

# This directory has no setup.sh, so its scripts and its subtree should load.
mkdir -p "$tmp/plain/nested_plain" "$tmp/plain/boundary/grandchild"
cat > "$tmp/plain/plain_loaded.sh" <<'SCRIPT'
F_TEST_PLAIN_NORMAL=1
SCRIPT
cat > "$tmp/plain/_plain_ignored.sh" <<'SCRIPT'
F_TEST_PLAIN_UNDERSCORE=1
SCRIPT
cat > "$tmp/plain/nested_plain/nested_loaded.sh" <<'SCRIPT'
F_TEST_NESTED_NORMAL=1
SCRIPT

# A directory with setup.sh is a boundary: load only setup.sh and do not scan
# sibling scripts or descend into its child folders unless setup.sh opts in.
cat > "$tmp/plain/boundary/setup.sh" <<'SCRIPT'
F_TEST_BOUNDARY_SETUP=1
SCRIPT
cat > "$tmp/plain/boundary/sibling_should_not_load.sh" <<'SCRIPT'
F_TEST_BOUNDARY_SIBLING=1
SCRIPT
cat > "$tmp/plain/boundary/_ignored.sh" <<'SCRIPT'
F_TEST_BOUNDARY_UNDERSCORE=1
SCRIPT
cat > "$tmp/plain/boundary/grandchild/grandchild_should_not_load.sh" <<'SCRIPT'
F_TEST_BOUNDARY_GRANDCHILD=1
SCRIPT

# An explicit setup can opt into loading its own module directory.
mkdir -p "$tmp/explicit"
cat > "$tmp/explicit/setup.sh" <<'SCRIPT'
F_TEST_EXPLICIT_SETUP=1
__f_load_module_dir "${BASH_SOURCE[0]}"
SCRIPT
cat > "$tmp/explicit/explicit_sibling.sh" <<'SCRIPT'
F_TEST_EXPLICIT_SIBLING=1
SCRIPT
mkdir -p "$tmp/explicit/child_boundary" "$tmp/_explicit_ignored"
cat > "$tmp/explicit/child_boundary/setup.sh" <<'SCRIPT'
F_TEST_EXPLICIT_CHILD_SETUP=1
SCRIPT
cat > "$tmp/explicit/child_boundary/sibling_should_not_load.sh" <<'SCRIPT'
F_TEST_EXPLICIT_CHILD_SIBLING=1
SCRIPT
cat > "$tmp/_explicit_ignored/setup.sh" <<'SCRIPT'
F_TEST_EXPLICIT_UNDERSCORE_DIR_SETUP=1
SCRIPT
cat > "$tmp/_explicit_ignored/sibling.sh" <<'SCRIPT'
F_TEST_EXPLICIT_UNDERSCORE_DIR_SIBLING=1
SCRIPT

if ! bash -c '
  source "$1/setup.sh"
  __f_load_module_dir "$1/_explicit_ignored/setup.sh"
  [[ "${F_TEST_ROOT_NORMAL:-}" == 1 ]] || exit 11
  [[ -z "${F_TEST_ROOT_UNDERSCORE:-}" ]] || exit 12
  [[ -z "${F_TEST_ROOT_UNDERSCORE_DIR_SETUP:-}" ]] || exit 24
  [[ -z "${F_TEST_ROOT_UNDERSCORE_DIR_SCRIPT:-}" ]] || exit 25
  [[ -z "${F_TEST_ROOT_UNDERSCORE_DIR_NESTED:-}" ]] || exit 26
  [[ "${F_TEST_PLAIN_NORMAL:-}" == 1 ]] || exit 13
  [[ -z "${F_TEST_PLAIN_UNDERSCORE:-}" ]] || exit 14
  [[ -z "${F_TEST_NESTED_UNDERSCORE_DIR_SETUP:-}" ]] || exit 27
  [[ -z "${F_TEST_NESTED_UNDERSCORE_DIR_SCRIPT:-}" ]] || exit 28
  [[ -z "${F_TEST_NESTED_UNDERSCORE_DIR_NESTED:-}" ]] || exit 29
  [[ "${F_TEST_NESTED_NORMAL:-}" == 1 ]] || exit 15
  [[ "${F_TEST_BOUNDARY_SETUP:-}" == 1 ]] || exit 16
  [[ -z "${F_TEST_BOUNDARY_SIBLING:-}" ]] || exit 17
  [[ -z "${F_TEST_BOUNDARY_UNDERSCORE:-}" ]] || exit 18
  [[ -z "${F_TEST_BOUNDARY_GRANDCHILD:-}" ]] || exit 19
  [[ "${F_TEST_EXPLICIT_SETUP:-}" == 1 ]] || exit 20
  [[ "${F_TEST_EXPLICIT_SIBLING:-}" == 1 ]] || exit 21
  [[ "${F_TEST_EXPLICIT_CHILD_SETUP:-}" == 1 ]] || exit 22
  [[ -z "${F_TEST_EXPLICIT_CHILD_SIBLING:-}" ]] || exit 23
  [[ -z "${F_TEST_EXPLICIT_UNDERSCORE_DIR_SETUP:-}" ]] || exit 30
  [[ -z "${F_TEST_EXPLICIT_UNDERSCORE_DIR_SIBLING:-}" ]] || exit 31
' _ "$tmp"; then
  printf 'FAIL: loader did not follow setup.sh boundaries, recursion, and underscore exclusions\n' >&2
  exit 1
fi

printf 'PASS: setup.sh boundaries, no-setup recursion, and underscore-prefixed file/directory exclusions\n'
