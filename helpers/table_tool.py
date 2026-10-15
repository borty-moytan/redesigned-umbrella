#!/usr/bin/env python3
"""Pretty-print CSV/delimiter-separated text using only Python's standard library."""
import argparse
import csv
import io
import os
import sys
import unicodedata
from typing import List, Optional

ALIASES = {
    "comma": ",", "csv": ",", "tab": "\t", r"\t": "\t", "tsv": "\t",
    "pipe": "|", "semicolon": ";", "semi": ";", "colon": ":",
    "space": " ", r"\s": " ",
}


def resolve_sep(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    value = ALIASES.get(value.lower(), value)
    # Common escapes are useful when typing commands in a shell.
    value = value.replace(r"\t", "\t").replace(r"\n", "\n").replace(r"\|", "|").replace(r"\\", "\\")
    return value


def parse_args():
    parser = argparse.ArgumentParser(
        prog="f_table",
        description="Render CSV or delimiter-separated text as a readable terminal table.",
        epilog="Separators: comma, tab/\\t, pipe/|, semicolon/;, colon/:, space, or a literal delimiter.",
    )
    parser.add_argument("--sep", "--delimiter", "-d", dest="sep", help="delimiter (auto-detected when omitted)")
    parser.add_argument("--no-header", action="store_true", help="do not style the first row as a header")
    parser.add_argument("--plain", action="store_true", help="use aligned columns without a box border")
    parser.add_argument("--no-color", action="store_true", help="disable ANSI styling")
    parser.add_argument("items", nargs="*", help="optional FILE and/or separator; use - for stdin")
    return parser.parse_args()


def identify_items(items):
    source = "-"
    sep = None
    rest = list(items)
    if rest and (rest[0] == "-" or os.path.isfile(rest[0]) or "/" in rest[0] or rest[0].lower().endswith((".csv", ".tsv", ".psv", ".ssv"))):
        source = rest.pop(0)
    if rest:
        if len(rest) > 1:
            raise ValueError("too many positional arguments; use --sep for clarity")
        sep = rest[0]
    return source, sep


def read_rows(source: str, sep: Optional[str]) -> List[List[str]]:
    if source == "-":
        if sys.stdin.isatty():
            raise ValueError("no input provided; pass a filename or pipe text into f_table")
        text = sys.stdin.read()
        extension = ""
    else:
        try:
            with open(source, "r", encoding="utf-8-sig", newline="") as stream:
                text = stream.read()
        except OSError as exc:
            raise ValueError(f"cannot read {source!r}: {exc}") from exc
        extension = os.path.splitext(source)[1].lower()
    if not text.strip():
        return []

    actual_sep = resolve_sep(sep)
    if actual_sep is None:
        if extension == ".tsv":
            actual_sep = "\t"
        elif extension == ".psv":
            actual_sep = "|"
        elif extension == ".ssv":
            actual_sep = ";"
        else:
            try:
                sample = text[:8192]
                actual_sep = csv.Sniffer().sniff(sample, delimiters=",\t;|:").delimiter
            except csv.Error:
                actual_sep = ","

    lines = text.splitlines()
    if actual_sep in (" ", "\n"):
        rows = [line.split() for line in lines if line.strip()]
    elif len(actual_sep) == 1:
        try:
            # StringIO(newline="") lets the CSV parser correctly retain quoted
            # fields which contain embedded newlines.
            rows = list(csv.reader(io.StringIO(text, newline=""), delimiter=actual_sep,
                                   skipinitialspace=True, strict=True))
        except csv.Error as exc:
            raise ValueError(f"malformed delimited input: {exc}") from exc
    else:
        # Multi-character separators are supported; CSV quoting semantics only
        # apply to single-character delimiters (the CSV standard's restriction).
        rows = [line.split(actual_sep) for line in lines]
    rows = [[cell.strip().replace("\r\n", " ↵ ").replace("\n", " ↵ ").replace("\r", " ↵ ") for cell in row]
            for row in rows if row and any(cell.strip() for cell in row)]
    if not rows:
        return []
    max_columns = max(map(len, rows))
    for row in rows:
        row.extend([""] * (max_columns - len(row)))
    return rows


def visible_width(text: str) -> int:
    total = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return total


def pad(text: str, width: int) -> str:
    return text + " " * max(0, width - visible_width(text))


def render(rows: List[List[str]], has_header: bool, plain: bool, color: bool) -> None:
    if not rows:
        print("(no rows)")
        return
    columns = max(map(len, rows))
    widths = [max(visible_width(row[i]) for row in rows) for i in range(columns)]
    reset = "\033[0m" if color else ""
    bold = "\033[1m" if color else ""
    cyan = "\033[36m" if color else ""

    def cell_row(row, header=False):
        cells = []
        for index in range(columns):
            value = pad(row[index], widths[index])
            if header and color:
                value = f"{bold}{value}{reset}"
            cells.append(value)
        if plain:
            return "  " + "  |  ".join(cells)
        return "│ " + " │ ".join(cells) + " │"

    if plain:
        for idx, row in enumerate(rows):
            print(cell_row(row, has_header and idx == 0))
            if has_header and idx == 0:
                print("  " + "--+--".join("-" * width for width in widths))
        return

    top = "┌" + "┬".join("─" * (width + 2) for width in widths) + "┐"
    middle = "├" + "┼".join("─" * (width + 2) for width in widths) + "┤"
    bottom = "└" + "┴".join("─" * (width + 2) for width in widths) + "┘"
    print(f"{cyan}{top}{reset}")
    for idx, row in enumerate(rows):
        print(cell_row(row, has_header and idx == 0))
        if has_header and idx == 0 and len(rows) > 1:
            print(f"{cyan}{middle}{reset}")
    print(f"{cyan}{bottom}{reset}")


def main() -> int:
    args = parse_args()
    try:
        source, positional_sep = identify_items(args.items)
        if args.sep is not None and positional_sep is not None:
            raise ValueError("provide a separator either positionally or with --sep, not both")
        sep = args.sep if args.sep is not None else positional_sep
        rows = read_rows(source, sep)
    except ValueError as exc:
        print(f"f_table: {exc}", file=sys.stderr)
        return 2
    color = sys.stdout.isatty() and not args.no_color and "NO_COLOR" not in os.environ and os.environ.get("TERM", "dumb") != "dumb"
    render(rows, not args.no_header, args.plain, color)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
