#!/usr/bin/env python3
"""Local JSON history backend for f_cp, f_rsync, and mdlog_vw.

Only Python's standard library is used. Historical commands are replayed with
subprocess argument vectors (never a shell), and require an explicit RUN
confirmation unless --yes is supplied.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import fcntl
import json
import os
import shlex
import shutil
import subprocess
import sys
import textwrap
import uuid
from typing import Any, Dict, List, Optional, Sequence, Tuple

LOG_NAME = ".f_copy.mdlog"

# GNU cp options which take a required separate argument.
_CP_LONG_REQUIRED = {"--target-directory", "--suffix", "--no-preserve"}
_CP_SHORT_REQUIRED = {"t", "S"}
# rsync's commonly used long options with required separate arguments. Options
# not in this set are treated as flags; =VALUE forms are naturally one token.
_RSYNC_LONG_REQUIRED = {
    "--address", "--backup-dir", "--block-size", "--bwlimit", "--checksum-seed",
    "--chmod", "--chown", "--compare-dest", "--compress-level", "--contimeout",
    "--copy-as", "--copy-dest", "--debug", "--exclude", "--exclude-from",
    "--filter", "--group", "--groupmap", "--iconv", "--include", "--include-from",
    "--log-file", "--log-file-format", "--max-alloc", "--max-delete", "--max-size",
    "--min-size", "--modify-window", "--out-format", "--outbuf", "--password-file",
    "--partial-dir", "--port", "--protocol", "--remote-option", "--rsync-path",
    "--rsync-path", "--rsh", "--sockopts", "--stop-after", "--stop-at",
    "--suffix", "--temp-dir", "--timeout", "--usermap", "--groupmap", "--user",
    "--write-batch", "--only-write-batch", "--read-batch", "--files-from",
    "--link-dest",
}
_RSYNC_SHORT_REQUIRED = {"e", "f", "M", "T", "B"}


class MdlogError(Exception):
    """A safe-to-display mdlog validation or I/O problem."""


def _parse_cp_operands(argv: Sequence[str]) -> Tuple[List[str], Optional[str]]:
    operands: List[str] = []
    target_directory: Optional[str] = None
    i = 0
    options_ended = False

    while i < len(argv):
        token = argv[i]
        if options_ended:
            operands.append(token)
            i += 1
            continue
        if token == "--":
            options_ended = True
            i += 1
            continue
        if token.startswith("--") and token != "--":
            name, equal, value = token.partition("=")
            if name == "--target-directory":
                if equal:
                    target_directory = value
                    i += 1
                elif i + 1 < len(argv):
                    target_directory = argv[i + 1]
                    i += 2
                else:
                    i += 1
                continue
            if name in _CP_LONG_REQUIRED:
                # These take a separate argument when not expressed with =.
                if equal:
                    i += 1
                else:
                    i += 2
                continue
            i += 1
            continue
        if token.startswith("-") and token != "-":
            cluster = token[1:]
            j = 0
            consumed_next = False
            while j < len(cluster):
                option = cluster[j]
                if option in _CP_SHORT_REQUIRED:
                    argument_in_same_token = cluster[j + 1 :]
                    if option == "t":
                        if argument_in_same_token:
                            target_directory = argument_in_same_token
                        elif i + 1 < len(argv):
                            target_directory = argv[i + 1]
                            consumed_next = True
                    elif not argument_in_same_token and i + 1 < len(argv):
                        # -S SUFFIX consumes an argument too, even though the
                        # suffix is not itself a destination operand.
                        consumed_next = True
                    if argument_in_same_token:
                        # An option's argument consumes the remainder of the cluster.
                        break
                    if consumed_next:
                        break
                j += 1
            i += 2 if consumed_next else 1
            continue
        operands.append(token)
        i += 1

    if target_directory is not None:
        return operands, target_directory
    if len(operands) < 2:
        return [], None
    return operands[:-1], operands[-1]


def _parse_rsync_operands(argv: Sequence[str]) -> Tuple[List[str], Optional[str]]:
    operands: List[str] = []
    i = 0
    options_ended = False

    while i < len(argv):
        token = argv[i]
        if options_ended:
            operands.append(token)
            i += 1
            continue
        if token == "--":
            options_ended = True
            i += 1
            continue
        if token.startswith("--") and token != "--":
            name, equal, _value = token.partition("=")
            if name in _RSYNC_LONG_REQUIRED and not equal:
                i += 2
            else:
                i += 1
            continue
        if token.startswith("-") and token != "-":
            cluster = token[1:]
            j = 0
            consumes_next = False
            while j < len(cluster):
                option = cluster[j]
                if option in _RSYNC_SHORT_REQUIRED:
                    if j + 1 == len(cluster):
                        consumes_next = True
                    # If characters follow an argument-taking short option,
                    # those characters are the argument (e.g. -e'ssh -p 22').
                    break
                j += 1
            i += 2 if consumes_next else 1
            continue
        operands.append(token)
        i += 1

    if len(operands) < 2:
        return [], None
    # rsync supports one or more source operands followed by one destination.
    return operands[:-1], operands[-1]


def _is_remote_rsync_destination(destination: str) -> bool:
    """Recognize rsync host:path and host::module destinations, not local paths."""
    if destination.startswith("/"):
        return False
    colon = destination.find(":")
    slash = destination.find("/")
    return colon >= 0 and (slash < 0 or colon < slash)


def _destination_details(
    kind: str, cwd: str, argv: Sequence[str]
) -> Tuple[List[str], Optional[str], Optional[str]]:
    if kind == "cp":
        sources, destination = _parse_cp_operands(argv)
    elif kind == "rsync":
        sources, destination = _parse_rsync_operands(argv)
    else:
        return [], None, None

    if not sources or not destination:
        return sources, destination, None
    if kind == "rsync" and _is_remote_rsync_destination(destination):
        return sources, destination, None

    candidate = destination if os.path.isabs(destination) else os.path.join(cwd, destination)
    # Keep the input path as passed in JSON, but resolve a path for filesystem tests.
    destination_directory = os.path.abspath(candidate)
    if not os.path.isdir(destination_directory):
        return sources, destination, None
    return sources, destination, destination_directory


def _read_entries_for_update(handle: Any, log_path: str) -> List[Dict[str, Any]]:
    handle.seek(0)
    content = handle.read()
    if not content.strip():
        return []
    try:
        entries = json.loads(content)
    except json.JSONDecodeError as exc:
        raise MdlogError(
            "Existing history file is not valid JSON; leaving it untouched: " + log_path
        ) from exc
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise MdlogError(
            "Existing history file must contain a JSON array of objects; leaving it untouched: "
            + log_path
        )
    return entries


def _append_to_log(log_path: str, record: Dict[str, Any]) -> None:
    # Lock the log file itself so concurrent successful copy commands cannot
    # overwrite one another's entries. Create new logs with owner-only access.
    fd = os.open(log_path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        entries = _read_entries_for_update(handle, log_path)
        entries.append(record)
        handle.seek(0)
        handle.truncate()
        json.dump(entries, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _create_record(
    kind: str,
    cwd: str,
    argv: Sequence[str],
    sources: Sequence[str],
    destination: str,
    destination_directory: str,
    replayed_from: Optional[str] = None,
) -> Dict[str, Any]:
    source_value: Any
    if len(sources) == 1:
        source_value = sources[0]
    else:
        source_value = list(sources)
    record: Dict[str, Any] = {
        "id": uuid.uuid4().hex[:12],
        "timestamp": _datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "tool": "f_cp" if kind == "cp" else "f_rsync",
        "command": kind,
        "source": source_value,
        "sources": list(sources),
        "destination": destination,
        "working_directory": cwd,
        "destination_directory": destination_directory,
        "argv": list(argv),
        "command_line": shlex.join([kind] + list(argv)),
    }
    if replayed_from:
        record["replayed_from"] = replayed_from
    return record


def append_successful_copy(
    kind: str,
    cwd: str,
    argv: Sequence[str],
    replayed_from: Optional[str] = None,
    warn: bool = True,
) -> bool:
    """Log a successful copy if the destination resolves to a local directory."""
    sources, destination, destination_directory = _destination_details(kind, cwd, argv)
    if not sources or not destination or not destination_directory:
        return False
    log_path = os.path.join(destination_directory, LOG_NAME)
    record = _create_record(
        kind, cwd, argv, sources, destination, destination_directory, replayed_from
    )
    try:
        _append_to_log(log_path, record)
    except (OSError, MdlogError) as exc:
        if warn:
            print("[f_copy] WARN: Could not append history: {}".format(exc), file=sys.stderr)
        return False
    return True


def _resolve_log_path(path_input: str) -> str:
    path = os.path.expandvars(path_input)
    if os.path.isdir(path):
        return os.path.join(os.path.abspath(path), LOG_NAME)
    if os.path.basename(path) == LOG_NAME or path.endswith(".mdlog"):
        return os.path.abspath(path)
    # A not-yet-existing path is treated as a directory for a useful error.
    return os.path.join(os.path.abspath(path), LOG_NAME)


def _load_entries(log_path: str) -> List[Dict[str, Any]]:
    try:
        with open(log_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise MdlogError("No history file found at: " + log_path) from exc
    except json.JSONDecodeError as exc:
        raise MdlogError("History file contains invalid JSON: " + log_path) from exc
    except OSError as exc:
        raise MdlogError("Could not read history file: {} ({})".format(log_path, exc)) from exc
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise MdlogError("History file must contain a JSON array of objects: " + log_path)
    return data


def _supports_color(stream: Any, disabled: bool) -> bool:
    return not disabled and hasattr(stream, "isatty") and stream.isatty() and os.environ.get("TERM", "dumb") != "dumb"


def _paint(value: str, code: str, enabled: bool) -> str:
    return "\033[{}m{}\033[0m".format(code, value) if enabled else value


def _short_source(entry: Dict[str, Any]) -> str:
    sources = entry.get("sources")
    if not isinstance(sources, list):
        source = entry.get("source", "<unknown>")
        sources = source if isinstance(source, list) else [source]
    if not sources:
        return "<unknown>"
    if len(sources) <= 3:
        return ", ".join(str(source) for source in sources)
    return ", ".join(str(source) for source in sources[:3]) + " … (+{} more)".format(len(sources) - 3)


def _display_entries(log_path: str, entries_newest_first: Sequence[Dict[str, Any]], color: bool) -> None:
    print(_paint("F COPY HISTORY", "1;36", color) + "  " + os.path.abspath(log_path))
    print(_paint("─" * 78, "2", color))
    if not entries_newest_first:
        print("No copy history entries yet.")
        return

    for display_number, entry in enumerate(entries_newest_first, start=1):
        timestamp = str(entry.get("timestamp", "<unknown time>"))
        tool = str(entry.get("tool", entry.get("command", "unknown")))
        ident = str(entry.get("id", "<no-id>"))
        title = "#{:<3} {}  {}  [id: {}]".format(display_number, timestamp, tool, ident)
        print(_paint(title, "1;32", color))
        fields = [
            ("SOURCE", _short_source(entry)),
            ("DESTINATION", str(entry.get("destination", "<unknown>"))),
            ("WORKED FROM", str(entry.get("working_directory", "<unknown>"))),
            ("COMMAND", str(entry.get("command_line", "<unavailable>"))),
        ]
        if entry.get("replayed_from"):
            fields.append(("REPLAY OF", str(entry["replayed_from"])))
        for label, value in fields:
            wrapped = textwrap.wrap(value, width=68, subsequent_indent="             ", break_long_words=True, break_on_hyphens=False) or [""]
            print("  {:<12}{}".format(label, wrapped[0]))
            for continuation in wrapped[1:]:
                print("  {:<12}{}".format("", continuation))
        print()
    print(_paint("Tip:", "1;36", color) + " mdlog_vw --run N replays entry N (newest is 1), after confirmation.")


def _confirm_replay(record: Dict[str, Any], yes: bool) -> bool:
    command = str(record.get("command", ""))
    argv = record.get("argv")
    cwd = str(record.get("working_directory", ""))
    if command not in ("cp", "rsync") or not isinstance(argv, list) or not all(isinstance(arg, str) for arg in argv):
        print("ERROR: This entry does not contain a replayable cp/rsync argument vector.", file=sys.stderr)
        return False
    if not cwd or not os.path.isdir(cwd):
        print("ERROR: The original working directory no longer exists: {}".format(cwd), file=sys.stderr)
        return False
    executable = shutil.which(command)
    if not executable:
        print("ERROR: '{}' is not installed or is not on PATH.".format(command), file=sys.stderr)
        return False

    print("\nHISTORICAL COMMAND REPLAY")
    print("  Command : {}".format(shlex.join([command] + argv)))
    print("  Ran from: {}".format(cwd))
    print("  Source  : {}".format(_short_source(record)))
    print("  Target  : {}".format(record.get("destination", "<unknown>")))
    print("\nWARNING: This performs real filesystem operations. Original options are preserved; rsync options such as --delete can remove files.")
    if not yes:
        if not sys.stdin.isatty():
            print("ERROR: Confirmation requires a terminal. Re-run interactively or pass --yes explicitly.", file=sys.stderr)
            return False
        try:
            response = input("Type RUN to execute this command, anything else to cancel: ")
        except EOFError:
            return False
        if response != "RUN":
            print("Replay cancelled.")
            return False
    return True


def _run_replay(record: Dict[str, Any], yes: bool) -> int:
    if not _confirm_replay(record, yes):
        return 2
    command = str(record["command"])
    argv = [str(arg) for arg in record["argv"]]
    cwd = str(record["working_directory"])
    try:
        completed = subprocess.run([command] + argv, cwd=cwd, check=False)
    except OSError as exc:
        print("ERROR: Could not launch historical command: {}".format(exc), file=sys.stderr)
        return 127

    if completed.returncode == 0:
        wrote = append_successful_copy(
            command,
            cwd,
            argv,
            replayed_from=str(record.get("id", "")) or None,
            warn=True,
        )
        if wrote:
            print("\nHistory updated with this replay.")
        else:
            print("\nCommand completed; no new history entry was needed for a non-directory destination.")
    else:
        print("\nHistorical command exited with status {}.".format(completed.returncode), file=sys.stderr)
    return completed.returncode if completed.returncode >= 0 else 128 + (-completed.returncode)


def _view_main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="mdlog_vw",
        description="View f_cp/f_rsync history and optionally replay a saved command.",
        epilog="Examples: mdlog_vw  |  mdlog_vw /path/to/destination  |  mdlog_vw --run 1 /path/to/destination",
    )
    parser.add_argument("path", nargs="?", default=".", help="destination directory or .f_copy.mdlog file (default: current directory)")
    replay_group = parser.add_mutually_exclusive_group()
    replay_group.add_argument("--run", type=int, metavar="N", help="replay entry N; newest entry is 1")
    replay_group.add_argument("--interactive", action="store_true", help="choose an entry to replay interactively")
    parser.add_argument("--yes", action="store_true", help="skip replay confirmation (use with --run or --interactive)")
    parser.add_argument("--limit", type=int, default=50, help="show at most N entries (default: 50)")
    parser.add_argument("--all", action="store_true", help="show all entries")
    parser.add_argument("--json", action="store_true", help="print the selected entries as JSON")
    parser.add_argument("--no-color", action="store_true", help="disable ANSI colors")
    args = parser.parse_args(list(argv))

    if args.limit < 1:
        parser.error("--limit must be at least 1")
    if args.yes and args.run is None and not args.interactive:
        parser.error("--yes requires --run or --interactive")

    log_path = _resolve_log_path(args.path)
    try:
        entries = _load_entries(log_path)
    except MdlogError as exc:
        print("mdlog_vw: {}".format(exc), file=sys.stderr)
        return 1

    newest_first = list(reversed(entries))
    visible = newest_first if args.all else newest_first[: args.limit]

    if args.json:
        print(json.dumps(visible, ensure_ascii=False, indent=2))
    else:
        _display_entries(log_path, visible, _supports_color(sys.stdout, args.no_color))

    if args.run is not None:
        if args.run < 1 or args.run > len(visible):
            print("mdlog_vw: entry {} is not in the displayed history ({} entries shown).".format(args.run, len(visible)), file=sys.stderr)
            return 2
        return _run_replay(visible[args.run - 1], args.yes)

    if args.interactive:
        if not sys.stdin.isatty():
            print("mdlog_vw: --interactive requires a terminal.", file=sys.stderr)
            return 2
        try:
            answer = input("Enter an entry number to replay, or press Enter to exit: ").strip()
        except EOFError:
            return 0
        if not answer:
            return 0
        if not answer.isdigit() or int(answer) < 1 or int(answer) > len(visible):
            print("mdlog_vw: invalid entry number.", file=sys.stderr)
            return 2
        return _run_replay(visible[int(answer) - 1], args.yes)

    return 0


def _append_main(argv: Sequence[str]) -> int:
    if len(argv) < 2:
        print("internal error: append needs command and working directory", file=sys.stderr)
        return 2
    kind, cwd = argv[0], argv[1]
    command_argv = list(argv[2:])
    if kind not in ("cp", "rsync"):
        print("internal error: unsupported copy command: {}".format(kind), file=sys.stderr)
        return 2
    if not os.path.isdir(cwd):
        print("[f_copy] WARN: Original working directory is unavailable; history was not saved.", file=sys.stderr)
        return 1
    # No log is an ordinary outcome when destination is not a local directory.
    append_successful_copy(kind, cwd, command_argv, warn=True)
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: mdlog_tool.py {append|view} ...", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if mode == "append":
        return _append_main(sys.argv[2:])
    if mode == "view":
        return _view_main(sys.argv[2:])
    print("Unknown internal operation: {}".format(mode), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
