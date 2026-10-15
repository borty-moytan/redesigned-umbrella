# f_copy — copy wrappers with local history

`f_copy` is a module for the F Bash toolkit. After sourcing `F/setup.sh`, it provides `f_cp`, `f_rsync`, and `mdlog_vw`. It uses only Bash, Python 3's standard library, and the existing `cp` / `rsync` commands. It makes no network requests and installs no packages.

## Commands

```bash
f_cp source.txt /path/to/existing-folder/
f_cp -av source-dir /path/to/destination-folder/
f_cp -t /path/to/destination-folder source-a.txt source-b.txt
f_rsync -av source-dir/ /path/to/destination-folder/

mdlog_vw                              # View ./.f_copy.mdlog
mdlog_vw /path/to/destination-folder  # View that folder's history
mdlog_vw /path/to/destination-folder/.f_copy.mdlog
mdlog_vw --limit 10 /path/to/destination-folder
mdlog_vw --json /path/to/destination-folder
mdlog_vw --run 1 /path/to/destination-folder
mdlog_vw --interactive /path/to/destination-folder
```

The first history item shown is the newest. Historical replay is opt-in and asks you to type `RUN` before executing. `--yes` bypasses that confirmation only when explicitly paired with `--run` or `--interactive`; use it carefully, especially with `rsync --delete` or other destructive options.

## Logging rules

- After a successful `f_cp` or `f_rsync`, the wrapper checks whether the destination operand resolves to a local directory. If it does, an entry is appended to `.f_copy.mdlog` inside that destination directory.
- The history is a JSON array of objects. Each record includes a timestamp with timezone, a unique ID, the wrapper and underlying command, the original source operand(s), the destination operand, the working directory where the command ran, the exact original argument vector, and a human-readable command line.
- If the file already exists, the new entry is appended. The writer locks the log file while updating it, so concurrent writes do not silently overwrite each other. New log files use owner-only permissions where supported.
- Copy and sync behavior is delegated to the real `cp` / `rsync` executable. The wrappers return the underlying command's exit status. Logging is best-effort: if it fails, a warning is printed, but a successful copy remains successful.
- Remote `rsync` destinations such as `host:/path` are not logged locally because the destination is not a local directory. Local destinations are supported.
- The argument parser handles regular `cp` usage, including multiple source files and `-t` / `--target-directory`, and ordinary rsync invocations with common long/short options. Unusual option combinations may limit the metadata extracted for display, but the underlying command still receives exactly the arguments the user passed.

## Replay safety

Replay uses a saved argument vector with `subprocess.run` and does not evaluate a shell command string. This protects spaces and shell metacharacters in paths from being interpreted as code. It restores the recorded working directory, then executes the original `cp` or `rsync` command. A successful replay creates a fresh history entry with `replayed_from` pointing to the historical entry ID.

## Install/load behavior

The parent F loader discovers `f_copy/setup.sh` as a directory boundary. That setup file explicitly calls `__f_load_module_dir` so its sibling utility scripts are loaded. The `_tests/` directory starts with an underscore and is therefore excluded from automatic loading.

To run the included regression tests:

```bash
bash /path/to/F/f_copy/_tests/test_f_copy.sh
```
