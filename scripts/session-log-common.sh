#!/usr/bin/env bash
# Shared helpers for the session-handoff hook pair. Sourced, never run.
#
# The slug keys every handoff file on disk, so session-end-log.sh and
# session-start-resume.sh MUST derive it identically:
#
#   <repo-root-path-relative-to-$HOME>[@<branch>]
#
# Path, not basename. A bare folder name collides across unrelated projects
# (`docs`, `db`, `tmp` would each be one bucket for the whole machine), and two
# checkouts that share a name can be different branches of different work.
# Repo root, not cwd, so a session started in a subdirectory of a repo shares
# that repo's handoffs.

handoff_compose_slug() { # $1 = repo root (or cwd), $2 = branch (may be empty)
  # Sets HANDOFF_PATH_SLUG and HANDOFF_SLUG from an explicit root and branch.
  # Split out so a historical handoff can be keyed by the branch recorded in
  # its header rather than by whatever is checked out now.
  local root="$1" rel bslug
  rel="${root#"$HOME"/}"
  [ -n "$rel" ] || rel="$root"
  # `/` and `-` both map to `-`, so foo-bar and foo/bar would share a folder. The
  # hash of the full root path tells them apart. The readable tail is capped so
  # the folder name stays well inside the 255-byte filename limit.
  HANDOFF_PATH_SLUG="$(printf '%s' "$rel" \
    | tr -c 'A-Za-z0-9_.-' '-' | sed 's/^-*//; s/-*$//' | tail -c 80 | sed 's/^-*//')"
  [ -n "$HANDOFF_PATH_SLUG" ] || HANDOFF_PATH_SLUG="unknown-project"
  HANDOFF_PATH_SLUG="$HANDOFF_PATH_SLUG-$(printf '%s' "$root" | handoff_hash8)"

  # Branch names can run to 100+ chars. The path is the identity and the branch
  # only disambiguates, so cap it to keep the folder name readable and well
  # inside the filesystem's 255-byte limit.
  bslug="$(printf '%s' "$2" \
    | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-48 | sed 's/^-*//; s/-*$//')"
  if [ -n "$bslug" ]; then
    HANDOFF_SLUG="${HANDOFF_PATH_SLUG}@${bslug}"
  else
    HANDOFF_SLUG="$HANDOFF_PATH_SLUG"
  fi
}

handoff_slugs() { # $1 = cwd
  # Sets: HANDOFF_PATH_SLUG (repo, any branch), HANDOFF_BRANCH,
  #       HANDOFF_SLUG (repo@branch, the folder handoffs are written to).
  local cwd="$1" root
  root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$cwd"
  HANDOFF_BRANCH="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
  handoff_compose_slug "$root" "$HANDOFF_BRANCH"
}

# sha1sum is GNU coreutils; macOS ships shasum. Both print "<digest>  <file>".
handoff_sha1() { # $1 = file -> prints the digest
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    shasum -a 1 "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# First 8 hex digits of a SHA-1 of stdin. sha1sum is GNU, shasum is macOS; cksum
# is the last resort, and its decimal output is cut to 8 characters as well.
handoff_hash8() { # stdin -> 8 chars
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 1 | cut -c1-8
  else
    cksum | cut -d' ' -f1 | cut -c1-8
  fi
}

# Modification time for ordering handoffs. GNU find takes %T@ (fractional
# seconds). Probed first, because it is the only form that gives sub-second
# precision. Without it, BSD stat -f %m is used, but only if `stat -f %m /`
# prints a bare integer: GNU `stat -f` is filesystem mode and must never be
# read as an mtime. The last resort is GNU stat -c %Y (whole seconds).
if find / -maxdepth 0 -printf '%T@' >/dev/null 2>&1; then
  handoff_mtime() { find "$1" -maxdepth 0 -printf '%T@' 2>/dev/null; }
else
  case "$(stat -f %m / 2>/dev/null)" in
    ''|*[!0-9]*) handoff_mtime() { stat -c %Y "$1" 2>/dev/null; } ;;
    *)           handoff_mtime() { stat -f %m "$1" 2>/dev/null; } ;;
  esac
fi

# timeout is GNU coreutils; macOS users typically have gtimeout (coreutils via
# Homebrew). With neither, a pure-bash watcher enforces the same bound.
handoff_timeout() { # $1 = seconds, rest = command (stdin is passed through)
  local secs="$1" pid watcher rc
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # Job control is switched on for this one spawn so the command gets its own
    # process group. The watcher then signals the whole group, not just the
    # direct child: a grandchild left holding the caller's stdout pipe would
    # otherwise keep $(...) waiting after the timeout has fired.
    # 0<&0: a background job in a non-interactive shell otherwise reads
    # /dev/null, and the summarizer prompt arrives on stdin.
    local had_monitor=0
    case $- in *m*) had_monitor=1 ;; esac
    set -m
    "$@" 0<&0 &
    pid=$!
    [ "$had_monitor" = 1 ] || set +m
    # The watcher's output goes to /dev/null so its orphaned sleep, which
    # outlives a killed watcher, does not hold open the caller's $(...) pipe.
    ( sleep "$secs"; kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null ) \
      >/dev/null 2>&1 &
    watcher=$!
    wait "$pid"
    rc=$?
    kill "$watcher" 2>/dev/null
    return "$rc"
  fi
}

# Runs a command under a bounded wait for the shared lock file $1 (flock), or a
# mkdir lock beside it when flock is missing. $2 = seconds to wait, rest = the
# command. The wait is bounded and the command runs even if the lock was not
# won: a stale lock must never block session start or close.
handoff_with_lock() {
  local lock="$1" secs="$2" dir tries got=0 mt prev=""
  shift 2
  if command -v flock >/dev/null 2>&1; then
    # A lock file that cannot be opened (read-only folder, a directory in its
    # place) must not cost the command: run it unlocked, as the mkdir path does.
    if ( exec 9>"$lock" ) 2>/dev/null; then
      ( flock -w "$secs" 9 2>/dev/null || true; "$@" ) 9>"$lock"
    else
      "$@"
    fi
    return 0
  fi
  dir="$lock.d"
  tries=$((secs * 10))
  while [ "$tries" -gt 0 ]; do
    if mkdir "$dir" 2>/dev/null; then got=1; break; fi
    # A holder that was killed never removes its dir. Nothing live holds a lock
    # for a minute, so an older one is reclaimed instead of waited out.
    mt="$(handoff_mtime "$dir")"
    # Renaming first means only one waiter can reclaim a given stale dir; the
    # others find it already gone and mv fails.
    if [ -n "$mt" ] && awk -v a="$mt" -v b="$(date +%s)" 'BEGIN { exit !(b - a > 60) }'; then
      mv "$dir" "$dir.stale.$$" 2>/dev/null && rmdir "$dir.stale.$$" 2>/dev/null
    fi
    sleep 0.1
    tries=$((tries - 1))
  done
  # The EXIT trap releases the dir if the command exits the shell early. The
  # caller's own EXIT trap is saved first and put back afterwards.
  if [ "$got" = 1 ]; then
    prev="$(trap -p EXIT)"
    trap 'rmdir "$dir" 2>/dev/null' EXIT
  fi
  "$@"
  if [ "$got" = 1 ]; then eval "${prev:-trap - EXIT}"; rmdir "$dir" 2>/dev/null; fi
  return 0
}

# Removes literal <handoff-note> tags so injected text cannot break out of the
# wrapper that marks it as a note.
strip_note_tags() { # stdin -> stdout
  sed -e 's#<handoff-note>##g' -e 's#</handoff-note>##g'
}

# Best-effort redaction of credential-shaped text, applied to the transcript
# excerpt before it is sent to the summarizer model, and to the summary before
# it is written. Regex scrubbing cannot guarantee that no secret gets through;
# it only catches the common shapes. Each rule is documented in README.md.
# Matches are replaced with [REDACTED]; line structure is preserved.
handoff_scrub() { # stdin -> stdout
  local script kw
  # Key-name group for the key=value rules. Bracket classes stand in for sed's
  # I flag, which GNU sed only. A bare `pass` may be followed by `phrase`, `code`
  # or an underscore-led tail, so `dbpass=`, `passphrase:` and `passcode=` are
  # caught. `Tests passed: 14` is left alone because `ed` is not in that list;
  # `bypass=on` is redacted too, which is accepted over-redaction.
  kw='(([Pp][Aa][Ss][Ss]([Pp][Hh][Rr][Aa][Ss][Ee]|[Cc][Oo][Dd][Ee])?(_[A-Za-z0-9_]*)?)|([Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd]|[Ww][Dd])|[Pp][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][-_]?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][-_]?[Kk][Ee][Yy])[A-Za-z0-9_]*)'
  script="$(cat <<'SED'
s#(^|[^A-Za-z0-9])sk-(ant-)?[A-Za-z0-9_-]{20,}#\1[REDACTED]#g
s#(^|[^A-Za-z0-9])sk_(live|test)_[A-Za-z0-9]{10,}#\1[REDACTED]#g
s#(AKIA|ASIA)[0-9A-Z]{16}#[REDACTED]#g
s#gh[pousr]_[A-Za-z0-9]{20,}#[REDACTED]#g
s#github_pat_[A-Za-z0-9_]{20,}#[REDACTED]#g
s#glpat-[A-Za-z0-9_-]{20,}#[REDACTED]#g
s#xox[abprs]-[A-Za-z0-9-]{10,}#[REDACTED]#g
s#AIza[0-9A-Za-z_-]{35}#[REDACTED]#g
s#([Bb]earer)[[:space:]]+[A-Za-z0-9._~+/=_-]{8,}#\1 [REDACTED]#g
s#([Bb]asic)[[:space:]]+[A-Za-z0-9+/]{8,}={0,2}#\1 [REDACTED]#g
s#eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*#[REDACTED]#g
s#([A-Za-z][A-Za-z0-9+.-]*://)[^/[:space:]@:]+:[^/[:space:]@]+@#\1[REDACTED]@#g
s#-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----[^-]*-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----#[REDACTED]#g
s#([Tt][Oo][Kk][Ee][Nn][[:space:]]+)[A-Za-z0-9._~+/=-]{8,}#\1[REDACTED]#g
s#((^|[^A-Za-z])[A-Z0-9_]*(PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|CREDENTIALS?|PRIVATE_KEY)[A-Z0-9_]*[[:space:]]+)[A-Za-z0-9/+=._-]{8,}#\1[REDACTED]#g
s#(@KW@"?[[:space:]]*[=:][[:space:]]*")[^"]*#\1[REDACTED]#g
s#(@KW@'?[[:space:]]*[=:][[:space:]]*')[^']*#\1[REDACTED]#g
s#(@KW@"?[[:space:]]*[=:][[:space:]]*)[^[:space:]"',;}]+#\1[REDACTED]#g
SED
)"
  script="${script//@KW@/$kw}"
  # Multi-line PEM blocks need state across lines, which sed cannot hold
  # without eating to EOF on an unterminated BEGIN. awk buffers from a BEGIN
  # line and prints [REDACTED] only when the matching END arrives. A BEGIN with
  # no END is redacted to EOF: failing closed beats printing a key.
  sed -E -e "$script" | awk '
    /-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----/ && !inkey { inkey = 1 }
    inkey {
      if ($0 ~ /-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----/) { print "[REDACTED]"; inkey = 0 }
      next
    }
    { print }
    END { if (inkey) print "[REDACTED]" }
  '
}
