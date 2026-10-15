# F — modular Bash startup toolkit

A small, local-only Bash toolkit designed to be sourced from `~/.bashrc`. It uses Bash built-ins and ordinary system utilities; JSON and CSV formatting use Python's standard library, with a Perl `JSON::PP` backup for JSON operations. It does not install packages, make network requests, or add tracking.

## Install

Place the `F/` directory somewhere stable, for example `~/.config/F`, then add this line to `~/.bashrc`:

```bash
source "$HOME/.config/F/setup.sh"
```

Reload with `source ~/.bashrc` or open a new terminal. If you keep the downloaded folder at another path, adjust the source line accordingly.

## Directory layout

```text
F/
├── setup.sh                 # entry point and recursive module loader
├── errors.sh                # Python-like tracebacks; trap is opt-in
├── health.sh                # readable system snapshot
├── json.sh                  # f_json shell function
├── table.sh                 # f_table shell function
├── helpers/
│   ├── json_tool.py         # Python stdlib JSON implementation
│   ├── json_tool.pl         # Perl JSON::PP fallback
│   └── table_tool.py        # Python stdlib CSV/delimited table renderer
└── modules/
    ├── setup.sh
    └── example/
        ├── setup.sh
        └── greeting.sh
```

At each module directory, the loader sources that directory's `*.sh` files (excluding its `setup.sh`) first, then visits child directories that contain their own `setup.sh`. File and directory discovery is lexicographic according to Bash's glob ordering. Folders without `setup.sh` are ignored, so `helpers/` is not treated as a Bash module. The loader skips directories already loaded in the current shell.

### Add a module

Create `F/modules/my-tool/setup.sh` and put Bash files beside it. The setup file can be as simple as:

```bash
if declare -F __f_load_module_dir >/dev/null 2>&1; then
  __f_load_module_dir "${BASH_SOURCE[0]}"
fi
```

The loader sources other `*.sh` files in `my-tool/`, then any child folders which have their own `setup.sh`. Use function and variable names with your own prefix to avoid collisions.

## Utilities

### Structured error logger

- `f_log_error [EXIT_STATUS] [MESSAGE]` prints a traceback-style error record to stderr.
- `f_enable_error_trap` enables an `ERR` trap for the current shell.
- `f_enable_error_trap --inherit` also enables Bash `errtrace` so errors inside functions can be caught.
- `f_disable_error_trap` removes the F trap and restores a previously installed `ERR` trap.

The trap is deliberately **not enabled automatically**: a global `ERR` trap can change the feel and behaviour of an interactive shell. It also does not silently enable `set -e`. Call `f_enable_error_trap` when you explicitly want it.

### System health

```bash
f_health             # inspect the current directory's filesystem and machine snapshot
f_health /var/log    # inspect a specific existing directory or path
```

Shows date/time, uptime, OS/kernel, architecture, load averages, RAM/swap, size of the selected directory, filesystem free/used space, and path. It only reads local system information.

### JSON get/update

`f_json` accepts a JSON filename or reads JSON from a pipe. Dotted paths traverse objects and existing arrays (numeric array indexes are supported for reading).

```bash
f_json config.json                         # pretty-print the document
f_json config.json app.theme               # print one value
f_json config.json app.theme=dark           # store the plain string "dark"
f_json config.json app.retry_count=3        # store a JSON number
f_json config.json app.features='["a","b"]'  # store a JSON array
f_json config.json app.settings='{"x":true}' # store a JSON object
f_json config.json app.enabled = true       # also accepts spaced equals syntax
cat config.json | f_json app.theme          # read a value from stdin
cat config.json | f_json app.theme=dark     # transform streamed JSON to stdout
```

A value that is valid JSON is stored using its JSON type; anything else is stored as a plain string. Missing intermediate keys are created as objects. File updates are written to a temporary file in the same directory and atomically renamed into place; streamed input cannot be changed in place, so the modified document is printed to stdout for redirection. JSON operations need Python 3, Python, or Perl with its core `JSON::PP` module. No `jq` dependency is used.

> Caution: shell metacharacters and spaces should be quoted. For a string intended to be the literal text `true`, pass `app.value='"true"'` (the quoted JSON string) rather than `app.value=true` (a boolean).

### Table printing

```bash
f_table data.csv
f_table data.tsv
f_table --sep '|' data.txt
f_table data.txt ';'
cat data.csv | f_table
cat data.txt | f_table --sep '\t'
f_table --no-header data.csv
f_table --plain data.csv
f_table --no-color data.csv
```

Delimiter aliases include `comma`/`csv`, `tab`/`tsv`/`\t`, `pipe`/`|`, `semicolon`/`;`, `colon`/`:`, and `space`. When no delimiter is specified, the utility uses the extension when known or sniffs common delimiters. Single-character delimiters use Python's CSV parser, including quoted fields. Multi-character delimiters are split literally and do not have CSV quoting semantics.

## Notes

- No external downloads or third-party Python packages are used.
- No global `set -e`, `set -u`, `set -o pipefail`, or error traps are applied by sourcing `setup.sh`.
- Python helper scripts are invoked as needed and are not themselves sourced by Bash.
