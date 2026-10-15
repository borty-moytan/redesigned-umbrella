#!/usr/bin/env python3
"""Dependency-free JSON get/set helper used by F's f_json Bash function."""
import json
import os
import re
import sys
import tempfile


def usage_error(message: str, code: int = 2) -> "NoReturn":
    print(f"f_json: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_json(source: str):
    if source == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(source, "r", encoding="utf-8-sig") as stream:
                raw = stream.read()
        except OSError as exc:
            usage_error(f"cannot read {source!r}: {exc}", 1)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        usage_error(f"invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}", 1)


def parse_operation(args):
    if not args:
        return "get", None, None
    if len(args) == 1:
        if "=" in args[0]:
            path, raw = args[0].split("=", 1)
            if not path:
                usage_error("a dotted path is required before '='")
            return "set", path, raw
        return "get", args[0], None
    if len(args) >= 3 and args[1] == "=":
        return "set", args[0], " ".join(args[2:])
    usage_error("expected DOTTED.PATH, DOTTED.PATH=VALUE, or DOTTED.PATH = VALUE")


def decode_value(raw: str):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Unquoted input is a plain string; valid JSON literals and containers
        # retain their JSON types (number, boolean, null, array, object, string).
        return raw


def get_path(data, path: str):
    current = data
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and re.fullmatch(r"\d+", part) and int(part) < len(current):
            current = current[int(part)]
        else:
            usage_error(f"key path {path!r} does not exist (missing {part!r})", 1)
    return current


def set_path(data, path: str, value):
    if not isinstance(data, dict):
        usage_error("setting a dotted path requires the JSON root to be an object", 1)
    parts = path.split(".")
    if any(part == "" for part in parts):
        usage_error("dotted paths cannot contain empty key segments")
    current = data
    for part in parts[:-1]:
        child = current.get(part)
        if not isinstance(child, dict):
            child = {}
            current[part] = child
        current = child
    current[parts[-1]] = value


def write_atomically(filename: str, data) -> None:
    directory = os.path.dirname(os.path.abspath(filename)) or "."
    mode = None
    try:
        mode = os.stat(filename).st_mode & 0o777
    except OSError:
        pass
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=directory,
                                         prefix=".f-json-", suffix=".tmp", delete=False) as stream:
            temp_name = stream.name
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temp_name, mode)
        os.replace(temp_name, filename)
    except OSError as exc:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
        usage_error(f"cannot update {filename!r}: {exc}", 1)


def print_value(value) -> None:
    if isinstance(value, str):
        print(value)
    elif value is None:
        print("null")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(value, ensure_ascii=False))


def main() -> int:
    args = sys.argv[1:]
    source = args.pop(0) if args and (args[0] == "-" or os.path.isfile(args[0]) or "/" in args[0] or args[0].endswith(".json")) else "-"
    if source == "-" and sys.stdin.isatty():
        usage_error("no JSON input provided; pass a filename or pipe JSON into f_json")
    mode, path, raw_value = parse_operation(args)
    data = read_json(source)
    if mode == "set":
        if source == "-":
            # Streamed JSON cannot be updated in-place; emit the transformed JSON
            # so it can be redirected to a new file.
            set_path(data, path, decode_value(raw_value))
            print(json.dumps(data, ensure_ascii=False, indent=2))
            return 0
        set_path(data, path, decode_value(raw_value))
        write_atomically(source, data)
        print_value(get_path(data, path))
        return 0
    if path is None:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_value(get_path(data, path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
