#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
F_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$F_ROOT/setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/f-copy-test.XXXXXX")" || fail 'mktemp failed'
trap 'rm -rf -- "$TMP_ROOT"' EXIT

WORK="$TMP_ROOT/work folder"
DEST="$TMP_ROOT/destination folder"
mkdir -p "$WORK" "$DEST"
printf 'alpha\n' > "$WORK/source one.txt"

cd -- "$WORK" || fail 'could not enter work folder'
f_cp 'source one.txt' "$DEST" || fail 'f_cp failed on a file into an existing folder'
[[ -f "$DEST/source one.txt" ]] || fail 'copied file is missing'
[[ -f "$DEST/.f_copy.mdlog" ]] || fail 'history file was not created'

python3 - "$DEST/.f_copy.mdlog" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    entries = json.load(f)
assert isinstance(entries, list) and len(entries) == 1, entries
entry = entries[0]
assert entry['tool'] == 'f_cp', entry
assert entry['command'] == 'cp', entry
assert entry['source'] == 'source one.txt', entry
assert entry['sources'] == ['source one.txt'], entry
assert entry['destination'] == sys.argv[1].rsplit('/.f_copy.mdlog', 1)[0], entry
assert entry['working_directory'] == sys.argv[1].rsplit('/destination folder/.f_copy.mdlog', 1)[0] + '/work folder', entry
assert entry['argv'] == ['source one.txt', sys.argv[1].rsplit('/.f_copy.mdlog', 1)[0]], entry
assert entry['timestamp'] and entry['id'], entry
PY
[[ $? == 0 ]] || fail 'first JSON record does not include required metadata'
pass 'f_cp copied and wrote correct metadata'

printf 'beta\n' > "$WORK/second.txt"
f_cp -v 'second.txt' "$DEST" || fail 'f_cp failed on second copy'
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$DEST/.f_copy.mdlog")" || fail 'could not read append count'
[[ "$COUNT" == 2 ]] || fail "expected history append to produce 2 entries, got $COUNT"
pass 'existing mdlog is appended, not overwritten'

# Test -t destination metadata parsing.
printf 'gamma\n' > "$WORK/third.txt"
f_cp -t "$DEST" third.txt || fail 'f_cp -t failed'
python3 - "$DEST/.f_copy.mdlog" <<'PY'
import json, sys
entries=json.load(open(sys.argv[1], encoding='utf-8'))
assert len(entries) == 3, len(entries)
assert entries[-1]['source'] == 'third.txt', entries[-1]
assert entries[-1]['destination'] == sys.argv[1].rsplit('/.f_copy.mdlog', 1)[0], entries[-1]
PY
[[ $? == 0 ]] || fail 'cp -t metadata was not parsed correctly'
pass 'cp -t / --target-directory metadata is handled'

# A destination that is a file rather than a directory should not get a log.
f_cp 'source one.txt' "$WORK/copied file.txt" || fail 'f_cp failed on file destination'
[[ ! -e "$WORK/.f_copy.mdlog" ]] || fail 'logged a destination that is a file'
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$DEST/.f_copy.mdlog")" || fail 'could not count history entries'
[[ "$COUNT" == 3 ]] || fail "file destination unexpectedly changed history (count=$COUNT)"
pass 'file destinations do not get a mdlog'

# A failed copy should preserve cp's nonzero status and not add a history item.
if f_cp 'missing-source-for-f_copy-test' "$DEST" 2>/dev/null; then
  fail 'f_cp should fail for a missing source'
fi
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$DEST/.f_copy.mdlog")" || fail 'could not count history entries after failed copy'
[[ "$COUNT" == 3 ]] || fail 'failed copy was incorrectly recorded'
pass 'failed copy status is preserved and not logged'

# Install a local rsync stand-in so this test works even where rsync is absent.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/rsync" <<'FAKE_RSYNC'
#!/usr/bin/env bash
# This test stand-in implements only the simple source destination case.
source_path="${1:?source required}"
destination_path="${2:?destination required}"
cp -- "$source_path" "$destination_path/"
FAKE_RSYNC
chmod +x "$FAKEBIN/rsync"
PATH="$FAKEBIN:$PATH"
printf 'delta\n' > "$WORK/rsync-source.txt"
f_rsync 'rsync-source.txt' "$DEST" || fail 'f_rsync failed with test stand-in'
python3 - "$DEST/.f_copy.mdlog" <<'PY'
import json, sys
entries=json.load(open(sys.argv[1], encoding='utf-8'))
assert len(entries) == 4, len(entries)
assert entries[-1]['tool'] == 'f_rsync', entries[-1]
assert entries[-1]['source'] == 'rsync-source.txt', entries[-1]
PY
[[ $? == 0 ]] || fail 'f_rsync did not append the expected record'
pass 'f_rsync writes metadata after a successful command'

# Exercise concurrent updates to ensure appends do not overwrite each other.
for n in 1 2 3; do printf 'concurrent %s\n' "$n" > "$WORK/concurrent-$n.txt"; done
for n in 1 2 3; do
  bash -c 'source "$1/setup.sh"; f_cp "$2" "$3"' _ "$F_ROOT/f_copy" "$WORK/concurrent-$n.txt" "$DEST" >/dev/null 2>&1 &
done
wait
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$DEST/.f_copy.mdlog")" || fail 'could not count concurrent history writes'
[[ "$COUNT" == 7 ]] || fail "concurrent history updates lost entries (count=$COUNT)"
pass 'concurrent appends are retained'

# Viewer emits readable history; JSON mode is useful for machine checks.
mdlog_vw "$DEST" >/dev/null || fail 'mdlog_vw failed to display history'
mdlog_vw --json "$DEST" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert len(data)==7; assert data[0]["tool"] == "f_cp"' || fail 'mdlog_vw --json output invalid'
pass 'mdlog_vw displays and exports history'

# Replay explicitly selected with --yes; it must create a new linked history item.
mdlog_vw --yes --run 1 "$DEST" >/dev/null || fail 'historical replay failed'
python3 - "$DEST/.f_copy.mdlog" <<'PY'
import json, sys
entries=json.load(open(sys.argv[1], encoding='utf-8'))
assert len(entries) == 8, len(entries)
assert entries[-1].get('replayed_from') == entries[-2]['id'], entries[-1]
PY
[[ $? == 0 ]] || fail 'successful replay did not append replay metadata'
pass 'historical command replay requires opt-in and is logged'

printf '\nAll f_copy tests passed.\n'
