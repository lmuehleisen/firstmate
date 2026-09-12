#!/usr/bin/env bash
# Stow-pass integrity audit: removal accounting and perishable referent checks.
# Usage:
#   fm-stow-audit.sh snapshot
#   fm-stow-audit.sh verify
#   fm-stow-audit.sh referents
#
# `snapshot` copies the current startup-memory files (data/captain.md,
# data/captain-shared.md, data/learnings.md) into state/.stow-audit/ so the
# same pass's `verify` has a before-state to diff against; it overwrites any
# previous snapshot. `verify` diffs that snapshot against the edited files plus
# data/memory-archive.md and refuses (exit 1) while any removed entry's fact is
# absent from both, naming each unaccounted entry. `referents` checks every
# perishable (`<!--p:...-->`) entry's named backlog task ids against this
# home's backlog and surfaces (exit 1) each entry whose id is resolved; an id
# it cannot resolve reads `unknown`, never `open` and never `resolved`.
#
# ENTRY MODEL (shared by both checks). A heading line, a blank line, and a
# line holding only an HTML comment are structure, never entries. A top-level
# `- ` or `* ` bullet starts an entry and indented lines continue it; any
# other content line at column zero is a one-line entry of its own.
#
# COMPARISON RULE (verify). Entries are normalized: HTML comments (tier
# markers) stripped, lowercased, every non-alphanumeric run collapsed to one
# space. A snapshot entry is accounted for when, in this order:
#   1. its normalized text appears token-aligned inside a single entry of the
#      edited files (kept, possibly inside a merge) or of the archive
#      (archived verbatim with provenance); or
#   2. a single entry of the edited files or the archive contains at least two
#      thirds of its distinctive tokens - its deduplicated normalized tokens
#      of length >= 4 minus the fixed stopword list below - which is how a
#      genuine consolidation merge passes without a false alarm.
# An entry with fewer than three distinctive tokens is accounted only by rule
# 1. Everything else is unaccounted and refused by name. The rule is
# deliberately mechanical: it proves a removed fact's words survived
# somewhere recoverable, not that surviving prose still means the same thing.
#
# REFERENT RULE (referents). Only explicitly `<!--p:...-->`-marked entries are
# scanned, because the perishable tier is the one whose prose promises a
# checkable expiry condition; task mentions in other tiers are not expiry
# conditions and flagging them forever would train readers to ignore the
# check. A task id is any whole token shaped like fm-example-task-b8 (lowercase
# hyphenated segments ending in one or two letters plus one or two digits).
# Verdicts: a backlog row in state `done` is `resolved`; any other found state
# is `open`; a missing row (including one pruned past done_keep), an absent or
# failing tasks-axi, and an id past the probe cap are `unknown`.
#
# COST. Both checks are local text comparison over files bounded by the
# startup-memory budget, plus - for `referents` only - one bounded backlog
# read per unique named id, capped at FM_STOW_AUDIT_REFERENT_MAX (default 25)
# ids with FM_TASKS_AXI_TIMEOUT (default 20s) per read.
#
# Exit codes: 0 clean, 1 findings that need this pass's action, 2 usage or
# environment error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAP="$STATE/.stow-audit"
MEMORY_FILES="captain.md captain-shared.md learnings.md"

usage() {
  sed -n '2,56{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'stow-audit: %s\n' "$1" >&2
}

# Parse one memory file into one entry per output line:
# <label>\t<extra>\t<normalized>\t<original, tabs and newlines flattened>.
# <extra> is the caller-supplied second field (source file for snapshot
# entries, empty otherwise).
parse_entries() {  # <label> <extra> <file>
  local label=$1 extra=$2 file=$3
  [ -f "$file" ] || return 0
  awk -v label="$label" -v extra="$extra" '
    function flush(   norm, orig) {
      if (cur == "") return
      orig = cur
      gsub(/\t/, " ", orig)
      norm = cur
      gsub(/<!--[^>]*-->/, " ", norm)
      norm = tolower(norm)
      gsub(/[^a-z0-9]+/, " ", norm)
      sub(/^ +/, "", norm)
      sub(/ +$/, "", norm)
      if (norm != "") printf "%s\t%s\t%s\t%s\n", label, extra, norm, orig
      cur = ""
    }
    /^[ \t]*$/ { flush(); next }
    /^#/ { flush(); next }
    /^[ \t]*<!--[^>]*-->[ \t]*$/ { flush(); next }
    /^[-*] / { flush(); cur = $0; next }
    /^[ \t]/ { if (cur != "") { cur = cur " " $0; next } }
    { flush(); cur = $0; flush() }
    END { flush() }
  ' "$file"
}

snapshot() {
  mkdir -p "$SNAP"
  local file present='' absent=''
  for file in $MEMORY_FILES; do
    rm -f "$SNAP/$file"
    if [ -f "$DATA/$file" ]; then
      cp "$DATA/$file" "$SNAP/$file"
      present="$present${present:+,}$file"
    else
      absent="$absent${absent:+,}$file"
    fi
  done
  printf 'taken=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SNAP/meta"
  printf 'stow-audit: snapshot taken files=%s absent=%s\n' \
    "${present:-none}" "${absent:-none}"
}

verify() {
  if [ ! -f "$SNAP/meta" ]; then
    print_error "no snapshot for this pass - run 'fm-stow-audit.sh snapshot' before editing"
    return 2
  fi
  sed -n 's/^taken=/stow-audit: snapshot_taken=/p' "$SNAP/meta"
  local file rc=0
  {
    for file in $MEMORY_FILES; do
      parse_entries A '' "$DATA/$file"
    done
    parse_entries R '' "$DATA/memory-archive.md"
    for file in $MEMORY_FILES; do
      parse_entries S "data/$file" "$SNAP/$file"
    done
  } | awk '
    BEGIN {
      FS = "\t"
      nstop = split("with that this from when then they them must never " \
        "always only into over under after before each every their there " \
        "which while would should could does have been being will such " \
        "than these those what where because between through during " \
        "without within still also very more most some many much other " \
        "another same both either about against here", stopword, " ")
      for (i = 1; i <= nstop; i++) STOP[stopword[i]] = 1
    }
    $1 == "A" { A[++na] = $3; next }
    $1 == "R" { R[++nr] = $3; next }
    $1 != "S" { next }
    {
      total++
      file = $2; norm = $3; orig = $4
      if (contained(norm, A, na)) { kept++; next }
      if (contained(norm, R, nr)) { archived++; next }
      split("", d)
      n = split(norm, tok, " ")
      dc = 0
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (length(t) < 4 || (t in STOP) || (t in d)) continue
        d[t] = 1; dc++
      }
      if (dc >= 3 && (covered(d, dc, A, na) || covered(d, dc, R, nr))) {
        consolidated++; next
      }
      bad++
      printf "unaccounted: file=%s entry=\"%s\"\n", file, orig
    }
    function contained(norm, arr, n,   i) {
      for (i = 1; i <= n; i++)
        if (index(" " arr[i] " ", " " norm " ") > 0) return 1
      return 0
    }
    function covered(d, dc, arr, n,   i, j, m, t, hits, et, es) {
      for (i = 1; i <= n; i++) {
        m = split(arr[i], et, " ")
        split("", es)
        for (j = 1; j <= m; j++) es[et[j]] = 1
        hits = 0
        for (t in d) if (t in es) hits++
        if (3 * hits >= 2 * dc) return 1
      }
      return 0
    }
    END {
      printf "stow-audit: entries snapshot=%d kept=%d archived=%d consolidated=%d unaccounted=%d\n", \
        total, kept, archived, consolidated, bad
      if (bad > 0) {
        print "stow-audit: removal-audit REFUSED - archive each named entry with provenance or restore it, then re-run"
        exit 1
      }
      print "stow-audit: removal-audit ok"
    }
  ' || rc=$?
  return "$rc"
}

# Map one probed id to "<verdict>\t<detail>" using the backlog row libraries.
probe_id() {  # <id>
  local id=$1 state
  if fm_backlog_row_probe "$DATA" "$id" >/dev/null 2>&1; then :; fi
  case "$FM_BACKLOG_ROW_RESULT" in
    found)
      state=${FM_BACKLOG_ROW_STATE%% *}
      if [ "$state" = "done" ]; then
        printf 'resolved\tstate=done'
      else
        printf 'open\tstate=%s' "$state"
      fi
      ;;
    not_found)
      printf 'unknown\treason="not in backlog (possibly pruned)"'
      ;;
    *)
      printf 'unknown\treason="%s"' \
        "${FM_BACKLOG_ROW_ERROR:-backlog probe failed}"
      ;;
  esac
}

# Extract every candidate task-id token from one flattened entry line.
ids_in_entry() {  # <original entry text>
  printf '%s\n' "$1" | tr -c 'a-z0-9-' '\n' |
    grep -xE '[a-z][a-z0-9]*(-[a-z0-9]+)*-[a-z]{1,2}[0-9]{1,2}' |
    sort -u || true
}

referents() {
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  export FM_TASKS_AXI_TIMEOUT="${FM_TASKS_AXI_TIMEOUT:-20}"
  local cap="${FM_STOW_AUDIT_REFERENT_MAX:-25}"
  local tmp entries_file cache_file
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-audit.XXXXXX")
  # shellcheck disable=SC2064 # expand tmp now; it never changes afterwards.
  trap "rm -rf '$tmp'" RETURN
  entries_file="$tmp/entries"
  cache_file="$tmp/cache"
  : > "$entries_file"
  : > "$cache_file"
  local file line orig ids id verdict detail
  local checked=0 nids=0 resolved=0 open=0 unknown=0
  for file in $MEMORY_FILES; do
    parse_entries "data/$file" '' "$DATA/$file" |
      grep -F '<!--p:' >> "$entries_file" || true
  done
  # Probe each unique candidate id once, most-mentioned order irrelevant:
  # every id past the cap reads unknown rather than being silently skipped.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$nids" -ge "$cap" ]; then
      printf 'unknown\treason="probe cap %s reached"' "$cap" > "$tmp/verdict"
    else
      nids=$((nids + 1))
      probe_id "$id" > "$tmp/verdict"
    fi
    printf '%s\t%s\n' "$id" "$(cat "$tmp/verdict")" >> "$cache_file"
  done <<EOF
$(while IFS= read -r line; do
    orig=$(printf '%s\n' "$line" | cut -f4-)
    ids_in_entry "$orig"
  done < "$entries_file" | sort -u)
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file=$(printf '%s\n' "$line" | cut -f1)
    orig=$(printf '%s\n' "$line" | cut -f4-)
    ids=$(ids_in_entry "$orig")
    [ -n "$ids" ] || continue
    checked=$((checked + 1))
    for id in $ids; do
      verdict=$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$cache_file")
      detail=$(awk -F'\t' -v id="$id" '$1 == id { print $3; exit }' "$cache_file")
      case "$verdict" in
        resolved) resolved=$((resolved + 1)) ;;
        open) open=$((open + 1)) ;;
        *) verdict=unknown; unknown=$((unknown + 1)) ;;
      esac
      printf 'referent: file=%s id=%s verdict=%s %s entry="%s"\n' \
        "$file" "$id" "$verdict" "$detail" "$orig"
    done
  done < "$entries_file"
  printf 'stow-audit: referents entries=%d ids=%d resolved=%d open=%d unknown=%d\n' \
    "$checked" "$nids" "$resolved" "$open" "$unknown"
  if [ "$resolved" -gt 0 ]; then
    printf 'stow-audit: referent-check SURFACED - rewrite each resolved entry from current evidence or archive it with provenance this pass\n'
    return 1
  fi
  printf 'stow-audit: referent-check ok\n'
}

case "${1:-}" in
  snapshot)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    snapshot
    ;;
  verify)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    verify
    ;;
  referents)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    referents
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
