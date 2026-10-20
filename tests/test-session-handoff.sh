#!/usr/bin/env bash
# Tests for the session-handoff hook pair. Runs entirely inside a temp HOME, so
# the real ~/.claude is never read or written.
#   - session-end-log.sh: concurrency safety (two sessions closing in the same
#     folder must not clobber each other's resume prompt), excerpt capping,
#     secret scrubbing, and the opt-in key log.
#   - session-start-resume.sh: the resume prompt reaches the next session once.
#   - session-log-common.sh: the slug is path+branch, so folders that share a
#     basename stay apart; the scrubber redacts each credential shape.
#
# Ordering assertions rely on sub-second file mtimes (GNU find -printf). On BSD
# find, files written within the same second tie, and the suite will see that tie.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$(cd "$HERE/../plugin" && pwd)"
SCRIPTS="$CLAUDE_PLUGIN_ROOT/scripts"
HOOK="$SCRIPTS/session-end-log.sh"
START_HOOK="$SCRIPTS/session-start-resume.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
# BSD touch has no -d with dates or relative phrases ("30 days ago" is GNU-only),
# so stamp mtimes with -t CCYYMMDDhhmm[.ss], which both touch flavours accept.
stamp() { # $1 = "YYYY-MM-DD hh:mm:ss", rest = files
  local digits; digits="$(printf '%s' "$1" | tr -dc '0-9')"; shift
  touch -t "$(printf '%s' "$digits" | cut -c1-12).$(printf '%s' "$digits" | cut -c13-14)" "$@"
}

# Stub `claude` so the hook never calls the real summarizer.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
sleep "${STUB_DELAY:-0.4}"
tag="$(printf '%s' "$prompt" | grep -oE 'MARKER-[A-Z]+' | head -1)"
printf '===SUMMARY===\n- did %s\n===RESUME===\ncontinue %s\n' "$tag" "$tag"
STUB
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"
export HOME="$tmp/home"
mkdir -p "$HOME"

work="$tmp/work/myproj"
mkdir -p "$work"

# Both hooks key off this; the suite must agree with them rather than guess.
# shellcheck source=../plugin/scripts/session-log-common.sh
. "$SCRIPTS/session-log-common.sh"
handoff_slugs "$work"
slug="$HANDOFF_SLUG"

# A transcript the SessionEnd hook will accept: two text blocks (it logs
# nothing emptier) and enough tool_use blocks to clear the min-tool-calls gate,
# which is what separates real work from a one-shot question.
mk_transcript() { # $1=path $2=marker [$3=tool call count, default 6]
  local n="${3:-6}" i
  : > "$1"
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$2 first line\"}]}}" >> "$1"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"t$i\",\"input\":{}}]}}" >> "$1"
    i=$((i+1))
  done
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$2 second line\"}]}}" >> "$1"
}

mk_transcript "$tmp/t-a.jsonl" MARKER-AAA
mk_transcript "$tmp/t-b.jsonl" MARKER-BBB

payload() { printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$1" "$work" "$2"; }

payload "$tmp/t-a.jsonl" sess-aaa | "$HOOK" >/dev/null 2>&1 &
pa=$!
payload "$tmp/t-b.jsonl" sess-bbb | "$HOOK" >/dev/null 2>&1 &
pb=$!
wait $pa $pb

dir="$HOME/.claude/session-log/$slug"

# 1. Each session keeps its own resume file.
[ -f "$dir/sess-aaa.md" ] && grep -q 'MARKER-AAA' "$dir/sess-aaa.md" \
  && ok "session A resume file preserved" || bad "session A resume file preserved"
[ -f "$dir/sess-bbb.md" ] && grep -q 'MARKER-BBB' "$dir/sess-bbb.md" \
  && ok "session B resume file preserved" || bad "session B resume file preserved"

# 2. NEXT_PROMPT.md exists, names its session, and its header matches its body
#    (a clobbered write would pair one session's header with the other's prompt).
if [ -f "$dir/NEXT_PROMPT.md" ] \
  && { grep -q 'session: sess-aaa' "$dir/NEXT_PROMPT.md" && grep -q 'MARKER-AAA' "$dir/NEXT_PROMPT.md"; } \
  || { grep -q 'session: sess-bbb' "$dir/NEXT_PROMPT.md" && grep -q 'MARKER-BBB' "$dir/NEXT_PROMPT.md"; }; then
  ok "NEXT_PROMPT.md header matches its body"
else
  bad "NEXT_PROMPT.md header matches its body"
fi

# 3. Both sessions appear in the appended global log (no lost write).
log="$HOME/.claude/session-log/${slug}.md"
grep -q 'sess-aaa' "$log" && grep -q 'sess-bbb' "$log" \
  && ok "both sessions appended to global log" || bad "both sessions appended to global log"

# 4. Global log has exactly two session headers (no interleaved/torn append).
n="$(grep -c '^## .* — session ' "$log")"
[ "$n" = "2" ] && ok "global log has 2 clean session headers" || bad "global log headers: got $n want 2"

# 5. A lock held by someone else must not stall the hook past its usefulness:
#    it waits briefly, then proceeds rather than blocking session close.
mk_transcript "$tmp/t-c.jsonl" MARKER-CCC
if command -v flock >/dev/null 2>&1; then
  exec 8>"$dir/.lock"
  flock 8
  start="$(date +%s)"
  payload "$tmp/t-c.jsonl" sess-ccc | timeout 20 "$HOOK" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))
  exec 8>&-
  [ -f "$dir/sess-ccc.md" ] && ok "completes while lock is held" || bad "completes while lock is held"
  [ "$elapsed" -le 6 ] && ok "lock wait bounded (${elapsed}s)" || bad "lock wait too long (${elapsed}s)"
else
  ok "flock unavailable — lock-contention tests skipped"
fi

# 6. A huge transcript is capped to its tail before the summarizer sees it, so
#    the `claude -p` call cannot overrun the harness's SessionEnd timeout.
big="$tmp/t-big.jsonl"
: > "$big"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"MARKER-OLD start of session"}]}}' >> "$big"
filler="$(head -c 60000 /dev/zero | tr '\0' 'x')"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$filler\"}]}}" >> "$big"
# Real work, or the min-tool-calls gate skips it before the cap is reached.
for i in 1 2 3 4 5 6; do
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"b$i\",\"input\":{}}]}}" >> "$big"
done
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"MARKER-NEW end of session"}]}}' >> "$big"
payload "$big" sess-big | "$HOOK" >/dev/null 2>&1
if grep -q 'MARKER-NEW' "$dir/sess-big.md" && ! grep -q 'MARKER-OLD' "$dir/sess-big.md"; then
  ok "oversized transcript capped to its tail"
else
  bad "oversized transcript capped to its tail"
fi

# --- session-start-resume.sh ---------------------------------------------
start_payload() { printf '{"cwd":"%s","source":"startup"}' "$work"; }

# 7. The next session is handed the latest resume prompt as additionalContext.
out="$(start_payload | "$START_HOOK" 2>/dev/null)"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'MARKER-'; then
  ok "resume prompt injected at session start"
else
  bad "resume prompt injected at session start"
fi

# 8. The same handoff is not re-injected into every later session. Test 7 claimed
#    one handoff; the next start may legitimately serve a sibling that shares its
#    mtime (BSD stat has whole-second resolution, so parallel closes tie), so
#    assert on the claimed handoff's own "Handoff:" line, not on empty output.
claimed_line="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null \
  | grep -m1 '^Handoff: ')"
out2="$(start_payload | "$START_HOOK" 2>/dev/null)"
out2_ctx="$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
[ -n "$claimed_line" ] && ! printf '%s\n' "$out2_ctx" | grep -qxF "$claimed_line" \
  && ok "same handoff injected only once" || bad "same handoff injected only once"

# 9. A new close produces a new handoff, which is injected again.
mk_transcript "$tmp/t-d.jsonl" MARKER-DDD
payload "$tmp/t-d.jsonl" sess-ddd | "$HOOK" >/dev/null 2>&1
out3="$(start_payload | "$START_HOOK" 2>/dev/null)"
printf '%s' "$out3" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'MARKER-DDD' \
  && ok "new handoff injected after next close" || bad "new handoff injected after next close"

# 10. A project with no handoff stays silent.
empty_out="$(printf '{"cwd":"%s","source":"startup"}' "$tmp/work/otherproj" | "$START_HOOK" 2>/dev/null)"
[ -z "$empty_out" ] && ok "no handoff — no output" || bad "no handoff — no output"

# 11. A stale handoff is not resurrected (clear the consumed ledger first, so
#     age is what rejects it rather than the dedup check).
rm -f "$dir/.consumed" 2>/dev/null
stamp '2020-01-01 00:00:00' "$dir"/*.md 2>/dev/null
stale_out="$(start_payload | "$START_HOOK" 2>/dev/null)"
[ -z "$stale_out" ] && ok "stale handoff skipped" || bad "stale handoff skipped"

# 12. Two sessions starting at once must not both claim the same handoff.
rm -f "$dir/.consumed" 2>/dev/null
touch "$dir/sess-ddd.md" 2>/dev/null
for i in 1 2 3 4; do
  start_payload | SESSION_HANDOFF_CLAIM_DELAY=0.3 "$START_HOOK" > "$tmp/start.$i" 2>/dev/null &
done
wait
# grep -lc is not portable: BSD grep prints a count line per file as well as the
# filename, so the count was 5 on macOS. -l alone lists only the matching files.
claimed="$(grep -l . "$tmp"/start.[1-4] 2>/dev/null | wc -l | tr -d ' ')"
[ "$claimed" = "1" ] && ok "concurrent starts claim the handoff once" \
  || bad "concurrent starts claim the handoff once (got $claimed)"
d_digest="$(handoff_sha1 "$dir/sess-ddd.md")"
n_digest="$(grep -cxF "$d_digest" "$dir/.consumed" 2>/dev/null || echo 0)"
[ "$n_digest" = "1" ] && ok "claimed handoff recorded once" \
  || bad "claimed handoff recorded once (got $n_digest)"

# 13. A different project's folder must not serve this project's handoff.
other="$tmp/work/otherproj"
mkdir -p "$other"
mk_transcript "$tmp/t-e.jsonl" MARKER-EEE
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-eee"}' "$tmp/t-e.jsonl" "$other" \
  | "$HOOK" >/dev/null 2>&1
oout="$(printf '{"cwd":"%s","source":"startup"}' "$other" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$oout" | grep -q 'MARKER-EEE' && ! printf '%s' "$oout" | grep -q 'MARKER-DDD' \
  && ok "handoff is per project folder" || bad "handoff is per project folder"

# 14. The nested summarizer session must not consume a pending handoff.
rm -f "$dir/.consumed" 2>/dev/null
touch "$dir/sess-ddd.md" 2>/dev/null
nested="$(start_payload | SESSION_HANDOFF_NO_RECURSE=1 "$START_HOOK" 2>/dev/null)"
[ -z "$nested" ] && [ ! -s "$dir/.consumed" ] \
  && ok "recursion guard leaves handoff pending" || bad "recursion guard leaves handoff pending"

# 15. Two folders that share a basename are different work: `myproj` under a
#     second parent must not be served the first one's handoff.
twin="$tmp/work/elsewhere/myproj"
mkdir -p "$twin"
mk_transcript "$tmp/t-f.jsonl" MARKER-FFF
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-fff"}' "$tmp/t-f.jsonl" "$twin" \
  | "$HOOK" >/dev/null 2>&1
twin_out="$(printf '{"cwd":"%s","source":"startup"}' "$twin" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$twin_out" | grep -q 'MARKER-FFF' && ! printf '%s' "$twin_out" | grep -q 'MARKER-DDD' \
  && ok "same basename, different path — separate handoffs" \
  || bad "same basename, different path — separate handoffs"

# 16. A repo is keyed by its root, so a session started in a subdirectory
#     resumes the repo's handoff rather than opening a bucket of its own.
if command -v git >/dev/null 2>&1; then
  repo="$tmp/work/arepo"
  mkdir -p "$repo/sub/dir"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" checkout -q -b main 2>/dev/null
  mk_transcript "$tmp/t-g.jsonl" MARKER-GGG
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ggg"}' "$tmp/t-g.jsonl" "$repo" \
    | "$HOOK" >/dev/null 2>&1
  sub_out="$(printf '{"cwd":"%s","source":"startup"}' "$repo/sub/dir" | "$START_HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  printf '%s' "$sub_out" | grep -q 'MARKER-GGG' \
    && ok "subdirectory resumes the repo's handoff" || bad "subdirectory resumes the repo's handoff"

  # 17. A handoff left on another branch is still this repo's work.
  mk_transcript "$tmp/t-h.jsonl" MARKER-HHH
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-hhh"}' "$tmp/t-h.jsonl" "$repo" \
    | "$HOOK" >/dev/null 2>&1
  git -C "$repo" checkout -q -b feature 2>/dev/null
  br_out="$(printf '{"cwd":"%s","source":"startup"}' "$repo" | "$START_HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  printf '%s' "$br_out" | grep -q 'MARKER-HHH' \
    && ok "falls back to the repo's other branches" || bad "falls back to the repo's other branches"
else
  ok "git unavailable — repo-root and branch-fallback tests skipped"
fi

# 18. Claiming a handoff retires the older ones behind it: a backlog of
#     un-resumed sessions must not be served up one stale note at a time.
back="$tmp/work/backlog"
mkdir -p "$back"
handoff_slugs "$back"
bdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
sec=0
for m in III JJJ KKK; do
  mk_transcript "$tmp/t-$m.jsonl" "MARKER-$m"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-%s"}' "$tmp/t-$m.jsonl" "$back" "$m" \
    | "$HOOK" >/dev/null 2>&1
  # Distinct stamps: three touches inside one second tie on BSD stat.
  sec=$((sec + 1))
  stamp "$(date +%Y-%m-%d) 00:00:0$sec" "$bdir/sess-$m.md"
done
b1="$(printf '{"cwd":"%s","source":"startup"}' "$back" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
b2="$(printf '{"cwd":"%s","source":"startup"}' "$back" | "$START_HOOK" 2>/dev/null)"
printf '%s' "$b1" | grep -q 'MARKER-KKK' && [ -z "$b2" ] \
  && ok "newest handoff served, backlog retired" || bad "newest handoff served, backlog retired"

# 19. Retirement spans branch folders: claiming the newest handoff must also
#     retire an older one left on a different branch of the same repo, or the
#     next session is served a superseded note.
if command -v git >/dev/null 2>&1; then
  xrepo="$tmp/work/xrepo"
  mkdir -p "$xrepo"
  git -C "$xrepo" init -q 2>/dev/null
  git -C "$xrepo" checkout -q -b main 2>/dev/null
  mk_transcript "$tmp/t-l.jsonl" MARKER-LLL
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-lll"}' "$tmp/t-l.jsonl" "$xrepo" \
    | "$HOOK" >/dev/null 2>&1
  git -C "$xrepo" checkout -q -b second 2>/dev/null
  sleep 1
  mk_transcript "$tmp/t-m.jsonl" MARKER-MMM
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-mmm"}' "$tmp/t-m.jsonl" "$xrepo" \
    | "$HOOK" >/dev/null 2>&1
  git -C "$xrepo" checkout -q -b third 2>/dev/null
  x1="$(printf '{"cwd":"%s","source":"startup"}' "$xrepo" | "$START_HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  x2="$(printf '{"cwd":"%s","source":"startup"}' "$xrepo" | "$START_HOOK" 2>/dev/null)"
  printf '%s' "$x1" | grep -q 'MARKER-MMM' && [ -z "$x2" ] \
    && ok "backlog retired across branch folders" || bad "backlog retired across branch folders"
else
  ok "git unavailable — cross-branch retirement test skipped"
fi

# 20. A broken jq must not consume the handoff: recording the digest before the
#     payload exists would drop that session's note permanently.
nojq="$tmp/nojq"
mkdir -p "$nojq"
printf '#!/usr/bin/env bash\nexit 3\n' > "$nojq/jq"
chmod +x "$nojq/jq"
rm -f "$bdir/.consumed" 2>/dev/null
touch "$bdir/sess-KKK.md" 2>/dev/null
broken="$(printf '{"cwd":"%s","source":"startup"}' "$back" | PATH="$nojq:$PATH" "$START_HOOK" 2>/dev/null)"
recovered="$(printf '{"cwd":"%s","source":"startup"}' "$back" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
[ -z "$broken" ] && printf '%s' "$recovered" | grep -q 'MARKER-KKK' \
  && ok "broken jq leaves the handoff pending" || bad "broken jq leaves the handoff pending"

# 21. Two handoffs sharing an mtime are siblings, not a backlog: retiring the
#     tie would swallow a concurrently-closed session's note unread.
tie="$tmp/work/tie"
mkdir -p "$tie"
handoff_slugs "$tie"
tdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
for m in NNN OOO; do
  mk_transcript "$tmp/t-$m.jsonl" "MARKER-$m"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-%s"}' "$tmp/t-$m.jsonl" "$tie" "$m" \
    | "$HOOK" >/dev/null 2>&1
done
stamp '2026-01-02 03:04:05' "$tdir/sess-NNN.md" "$tdir/sess-OOO.md" 2>/dev/null
rm -f "$tdir/.consumed" 2>/dev/null
t1="$(printf '{"cwd":"%s","source":"startup"}' "$tie" | SESSION_HANDOFF_MAX_AGE_DAYS=99999 "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
t2="$(printf '{"cwd":"%s","source":"startup"}' "$tie" | SESSION_HANDOFF_MAX_AGE_DAYS=99999 "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
both="$(printf '%s\n%s\n' "$t1" "$t2" | grep -c -E 'MARKER-(NNN|OOO)')"
[ "$both" -ge 2 ] && ok "mtime tie serves both siblings" || bad "mtime tie serves both siblings (got $both)"

# 22. The handoffs a claim retires are listed by title in the injected context,
#     so a backlog on a branch that was put down stays visible instead of
#     disappearing into .consumed.
lst="$tmp/work/listing"
mkdir -p "$lst"
handoff_slugs "$lst"
ldir="$HOME/.claude/session-log/$HANDOFF_SLUG"
for m in PPP QQQ RRR; do
  mk_transcript "$tmp/t-$m.jsonl" "MARKER-$m"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-%s"}' "$tmp/t-$m.jsonl" "$lst" "$m" \
    | "$HOOK" >/dev/null 2>&1
done
stamp '2026-01-01 01:00:00' "$ldir/sess-PPP.md" \
  && stamp '2026-01-01 02:00:00' "$ldir/sess-QQQ.md" \
  && stamp '2026-01-01 03:00:00' "$ldir/sess-RRR.md" \
  || bad "could not stamp listing fixtures (later assertions are meaningless)"
rm -f "$ldir/.consumed" 2>/dev/null
lout="$(printf '{"cwd":"%s","source":"startup"}' "$lst" | SESSION_HANDOFF_MAX_AGE_DAYS=99999 "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if printf '%s' "$lout" | grep -q 'MARKER-RRR' \
  && printf '%s' "$lout" | grep -q 'sess-QQQ.md' \
  && printf '%s' "$lout" | grep -q 'sess-PPP.md'; then
  ok "retired handoffs listed alongside the served one"
else
  bad "retired handoffs listed alongside the served one"
fi

# 22b. A filename alone would still be there if every field rendered empty.
#      Assert the line is actually a title: stamped date, branch, summary text,
#      and a path abbreviated to ~ rather than the full home directory.
if printf '%s' "$lout" | grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}[^[]*\[.+\]$' \
  && printf '%s' "$lout" | grep -q 'MARKER-QQQ' \
  && printf '%s' "$lout" | grep -q '^  ~/.claude/session-log/' \
  && ! printf '%s' "$lout" | grep -q '(no summary)'; then
  ok "pending line renders date, branch, summary and ~-path"
else
  bad "pending line renders date, branch, summary and ~-path"
fi

# 22c. An mtime tie is a sibling still owed to someone, not backlog: it must
#      not be announced as retired, because the next start serves it in full.
tie2="$tmp/work/tie2"
mkdir -p "$tie2"
handoff_slugs "$tie2"
t2dir="$HOME/.claude/session-log/$HANDOFF_SLUG"
for m in TTT UUU; do
  mk_transcript "$tmp/t-$m.jsonl" "MARKER-$m"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-%s"}' "$tmp/t-$m.jsonl" "$tie2" "$m" \
    | "$HOOK" >/dev/null 2>&1
done
stamp '2026-02-02 02:00:00' "$t2dir/sess-TTT.md" "$t2dir/sess-UUU.md" 2>/dev/null
rm -f "$t2dir/.consumed" 2>/dev/null
tie_out="$(printf '{"cwd":"%s","source":"startup"}' "$tie2" | SESSION_HANDOFF_MAX_AGE_DAYS=99999 "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
served="$(printf '%s' "$tie_out" | grep -oE 'sess-(TTT|UUU)' | head -1)"
sibling="$([ "$served" = "sess-TTT" ] && echo sess-UUU || echo sess-TTT)"
printf '%s' "$tie_out" | grep -q "$sibling" \
  && bad "mtime-tied sibling not listed as retired (listed $sibling)" \
  || ok "mtime-tied sibling not listed as retired"

# 23. The listing must not resurrect them: the next start is silent, and the
#     served brief itself is never duplicated into its own pending list.
lout2="$(printf '{"cwd":"%s","source":"startup"}' "$lst" | SESSION_HANDOFF_MAX_AGE_DAYS=99999 "$START_HOOK" 2>/dev/null)"
[ -z "$lout2" ] && ok "listed handoffs stay retired" || bad "listed handoffs stay retired"
[ "$(printf '%s' "$lout" | grep -c 'sess-RRR.md')" = "1" ] \
  && ok "served handoff not repeated in its own list" \
  || bad "served handoff not repeated in its own list"

# 24. With nothing else pending, no empty list section is emitted.
solo="$tmp/work/solo"
mkdir -p "$solo"
mk_transcript "$tmp/t-SSS.jsonl" MARKER-SSS
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-SSS"}' "$tmp/t-SSS.jsonl" "$solo" \
  | "$HOOK" >/dev/null 2>&1
sout="$(printf '{"cwd":"%s","source":"startup"}' "$solo" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$sout" | grep -q 'MARKER-SSS' && ! printf '%s' "$sout" | grep -q 'never resumed' \
  && ok "no pending list when nothing is pending" || bad "no pending list when nothing is pending"

# 25. A session that never picked up a tool is a one-shot question, not work:
#     no summarizer call, no handoff file, nothing appended to the global log.
gate="$tmp/work/gate"
mkdir -p "$gate"
handoff_slugs "$gate"
gdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
mk_transcript "$tmp/t-VVV.jsonl" MARKER-VVV 0
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-VVV"}' "$tmp/t-VVV.jsonl" "$gate" \
  | "$HOOK" >/dev/null 2>&1
[ ! -e "$gdir/sess-VVV.md" ] && [ ! -e "$HOME/.claude/session-log/$HANDOFF_SLUG.md" ] \
  && ok "tool-less session writes no handoff" || bad "tool-less session writes no handoff"

# 26. Just under the threshold is still skipped; at the threshold it is kept.
mk_transcript "$tmp/t-WWW.jsonl" MARKER-WWW 4
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-WWW"}' "$tmp/t-WWW.jsonl" "$gate" \
  | "$HOOK" >/dev/null 2>&1
[ ! -e "$gdir/sess-WWW.md" ] && ok "below the tool-call gate is skipped" \
  || bad "below the tool-call gate is skipped"
mk_transcript "$tmp/t-XXX.jsonl" MARKER-XXX 5
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-XXX"}' "$tmp/t-XXX.jsonl" "$gate" \
  | "$HOOK" >/dev/null 2>&1
[ -s "$gdir/sess-XXX.md" ] && ok "at the tool-call gate is kept" \
  || bad "at the tool-call gate is kept"

# 27. The gate is tunable, so a setup that wants every session logged can have
#     it without editing the hook.
mk_transcript "$tmp/t-YYY.jsonl" MARKER-YYY 0
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-YYY"}' "$tmp/t-YYY.jsonl" "$gate" \
  | SESSION_HANDOFF_MIN_TOOL_CALLS=0 "$HOOK" >/dev/null 2>&1
[ -s "$gdir/sess-YYY.md" ] && ok "tool-call gate is env-tunable" || bad "tool-call gate is env-tunable"

# 28. The chain must survive a short continuation. A session that was served a
#     handoff consumed it; if the tool-call gate then drops that session, the
#     note is gone and nothing replaced it — the session after gets nothing.
chain="$tmp/work/chain"
mkdir -p "$chain"
handoff_slugs "$chain"
cdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
chain_start() { printf '{"cwd":"%s","source":"startup","session_id":"%s"}' "$chain" "$1"; }
mk_transcript "$tmp/t-ZA.jsonl" MARKER-ZA 9
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZA"}' "$tmp/t-ZA.jsonl" "$chain" \
  | "$HOOK" >/dev/null 2>&1
served="$(chain_start sess-ZB | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
mk_transcript "$tmp/t-ZB.jsonl" MARKER-ZB 2
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZB"}' "$tmp/t-ZB.jsonl" "$chain" \
  | "$HOOK" >/dev/null 2>&1
next="$(chain_start sess-ZC | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$served" | grep -q 'MARKER-ZA' && printf '%s' "$next" | grep -q 'MARKER-ZB' \
  && ok "short continuation still hands the thread on" \
  || bad "short continuation still hands the thread on"

# 29. A claimed session with nothing to say gives the handoff back rather than
#     swallowing it, so the next session is served the original note.
chain2="$tmp/work/chain2"
mkdir -p "$chain2"
handoff_slugs "$chain2"
c2dir="$HOME/.claude/session-log/$HANDOFF_SLUG"
mk_transcript "$tmp/t-ZD.jsonl" MARKER-ZD 9
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZD"}' "$tmp/t-ZD.jsonl" "$chain2" \
  | "$HOOK" >/dev/null 2>&1
printf '{"cwd":"%s","source":"startup","session_id":"sess-ZE"}' "$chain2" | "$START_HOOK" >/dev/null 2>&1
: > "$tmp/t-ZE.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}' >> "$tmp/t-ZE.jsonl"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZE"}' "$tmp/t-ZE.jsonl" "$chain2" \
  | "$HOOK" >/dev/null 2>&1
back="$(printf '{"cwd":"%s","source":"startup","session_id":"sess-ZF"}' "$chain2" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$back" | grep -q 'MARKER-ZD' && ok "empty continuation carries its note forward" \
  || bad "empty continuation carries its note forward"

# 29b. Carrying forward must not touch the shared ledger: the note's own digest
#      stays consumed, and a concurrent session's claim recorded there survives.
grep -q . "$c2dir/.consumed" 2>/dev/null && ok "carry-forward leaves the ledger alone" \
  || bad "carry-forward leaves the ledger alone"

# 29c. A summarizer that fails or times out must not swallow a claimed note
#      either. That exit is far more common than an empty transcript.
chain3="$tmp/work/chain3"
mkdir -p "$chain3"
handoff_slugs "$chain3"
c3dir="$HOME/.claude/session-log/$HANDOFF_SLUG"
mk_transcript "$tmp/t-ZH.jsonl" MARKER-ZH 9
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZH"}' "$tmp/t-ZH.jsonl" "$chain3" \
  | "$HOOK" >/dev/null 2>&1
printf '{"cwd":"%s","source":"startup","session_id":"sess-ZI"}' "$chain3" | "$START_HOOK" >/dev/null 2>&1
mk_transcript "$tmp/t-ZI.jsonl" MARKER-ZI 9
cat > "$tmp/bin/claude" <<'DEAD'
#!/usr/bin/env bash
cat >/dev/null
exit 1
DEAD
chmod +x "$tmp/bin/claude"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZI"}' "$tmp/t-ZI.jsonl" "$chain3" \
  | "$HOOK" >/dev/null 2>&1
cat > "$tmp/bin/claude" <<'STUB2'
#!/usr/bin/env bash
prompt="$(cat)"
sleep "${STUB_DELAY:-0.4}"
tag="$(printf '%s' "$prompt" | grep -oE 'MARKER-[A-Z]+' | head -1)"
printf '===SUMMARY===\n- did %s\n===RESUME===\ncontinue %s\n' "$tag" "$tag"
STUB2
chmod +x "$tmp/bin/claude"
dead_out="$(printf '{"cwd":"%s","source":"startup","session_id":"sess-ZJ"}' "$chain3" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
printf '%s' "$dead_out" | grep -q 'MARKER-ZH' && ok "failed summarizer carries the note forward" \
  || bad "failed summarizer carries the note forward"

# 30. The claim marker never outlives its session, whichever way the end hook
#     exits: sess-ZB left by the tool-call gate, sess-ZE by the empty-transcript
#     gate. A marker for a session that has not closed yet is expected to stay.
cl="$HOME/.claude/session-log/.claimed"
[ ! -e "$cl/sess-ZB" ] && [ ! -e "$cl/sess-ZE" ] \
  && ok "claim markers cleared by session end" || bad "claim markers cleared by session end"
# sess-ZC and sess-ZF claimed and never closed; without this the assertion above
# would pass just as well if the marker were never written at all.
[ -s "$cl/sess-ZC" ] && [ -s "$cl/sess-ZF" ] \
  && ok "open session keeps its claim marker" || bad "open session keeps its claim marker"

# 31. A transcript that goes malformed after its text blocks but before its
#     tool calls must not be read as a tool-less session: jq aborts at the bad
#     line, and only a clean parse is allowed to veto.
corrupt="$tmp/work/corrupt"
mkdir -p "$corrupt"
handoff_slugs "$corrupt"
xdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
: > "$tmp/t-ZG.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"MARKER-ZG one"}]}}' >> "$tmp/t-ZG.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"MARKER-ZG two"}]}}' >> "$tmp/t-ZG.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_' >> "$tmp/t-ZG.jsonl"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZG"}' "$tmp/t-ZG.jsonl" "$corrupt" \
  | "$HOOK" >/dev/null 2>&1
[ -s "$xdir/sess-ZG.md" ] && ok "corrupt transcript fails open, not silent" \
  || bad "corrupt transcript fails open, not silent"

# 32. The opening prompt reaches the summarizer. Claude Code writes it with
#     `content` as a bare string rather than the block array most turns use, so
#     a `.content[]?` walk drops the one turn that says what the session was
#     for. A short session then reads as one text line and is discarded by the
#     emptiness gate below it.
strmsg="$tmp/work/strmsg"
mkdir -p "$strmsg"
handoff_slugs "$strmsg"
sdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
: > "$tmp/t-ZK.jsonl"
# The marker lives only in the string-form prompt: if the summary carries it,
# nothing but that turn can have put it there.
printf '%s\n' '{"type":"user","message":{"content":"MARKER-ZK please inventory the repo"}}' >> "$tmp/t-ZK.jsonl"
i=0; while [ "$i" -lt 6 ]; do
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"z$i\",\"input\":{}}]}}" >> "$tmp/t-ZK.jsonl"
  i=$((i+1))
done
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' >> "$tmp/t-ZK.jsonl"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZK"}' "$tmp/t-ZK.jsonl" "$strmsg" \
  | "$HOOK" >/dev/null 2>&1
[ -s "$sdir/sess-ZK.md" ] && ok "string-form prompt clears the emptiness gate" \
  || bad "string-form prompt clears the emptiness gate"
grep -q 'MARKER-ZK' "$sdir/sess-ZK.md" 2>/dev/null \
  && ok "string-form prompt reaches the summarizer" \
  || bad "string-form prompt reaches the summarizer"

# 33. The string form is not prompts only: `/context` and `/cost` output, the
#     `<command-name>` wrapper and the harness's `<local-command-caveat>` all
#     arrive as bare strings too. Letting them into the excerpt is worse than
#     dropping the prompt was. The caveat is directive-shaped besides, and this
#     text is pasted straight into a prompt.
noise="$tmp/work/noise"
mkdir -p "$noise"
handoff_slugs "$noise"
ndir="$HOME/.claude/session-log/$HANDOFF_SLUG"
: > "$tmp/t-ZL.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"MARKER-ZL do the real work"}}' >> "$tmp/t-ZL.jsonl"
printf '%s\n' '{"type":"user","isMeta":true,"message":{"content":"NOISE-META ## Context Usage | tool | tokens |"}}' >> "$tmp/t-ZL.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"<command-name>NOISE-CMD</command-name>"}}' >> "$tmp/t-ZL.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"<local-command-stdout>NOISE-OUT</local-command-stdout>"}}' >> "$tmp/t-ZL.jsonl"
i=0; while [ "$i" -lt 6 ]; do
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"n$i\",\"input\":{}}]}}" >> "$tmp/t-ZL.jsonl"
  i=$((i+1))
done
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' >> "$tmp/t-ZL.jsonl"
# The stub echoes back every marker it is handed, so the summary is a faithful
# report of what the excerpt contained.
cat > "$tmp/bin/claude" <<'STUB3'
#!/usr/bin/env bash
prompt="$(cat)"
seen="$(printf '%s' "$prompt" | grep -oE '(MARKER|NOISE)-[A-Z]+' | sort -u | tr '\n' ' ')"
printf '===SUMMARY===\n- saw %s\n===RESUME===\ncontinue %s\n' "$seen" "$seen"
STUB3
chmod +x "$tmp/bin/claude"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ZL"}' "$tmp/t-ZL.jsonl" "$noise" \
  | "$HOOK" >/dev/null 2>&1
grep -q 'MARKER-ZL' "$ndir/sess-ZL.md" 2>/dev/null \
  && ok "real prompt survives the noise filter" || bad "real prompt survives the noise filter"
grep -q 'NOISE-' "$ndir/sess-ZL.md" 2>/dev/null \
  && bad "meta and command output kept out of the excerpt" \
  || ok "meta and command output kept out of the excerpt"

# --- secret scrubbing (handoff_scrub) -------------------------------------
# Each credential shape must come out as exactly the expected line. Exact
# comparison, not a grep, so a partial redaction also fails.
scrub_is() { # $1 = input line, $2 = expected output line, $3 = label
  local got
  got="$(printf '%s\n' "$1" | handoff_scrub)"
  [ "$got" = "$2" ] && ok "$3" || bad "$3 (got: $got)"
}
scrub_is 'key sk-''ant-api03-EXAMPLEEXAMPLEEXAMPLE' 'key [REDACTED]' \
  "scrub: Anthropic sk-ant key"
scrub_is 'openai sk-''proj-EXAMPLEEXAMPLEEXAMPLE' 'openai [REDACTED]' \
  "scrub: generic sk- key"
scrub_is 'id AK''IAIOSFODNN7EXAMPLE end' 'id [REDACTED] end' \
  "scrub: AWS access key id"
scrub_is 'use gh''p_EXAMPLEEXAMPLEEXAMPLE0123' 'use [REDACTED]' \
  "scrub: GitHub ghp_ token"
scrub_is 'use github_''pat_EXAMPLEEXAMPLEEXAMPLE' 'use [REDACTED]' \
  "scrub: GitHub fine-grained github_pat_ token"
scrub_is 'use gl''pat-EXAMPLEEXAMPLEEXAMPLE' 'use [REDACTED]' \
  "scrub: GitLab glpat- token"
scrub_is 'Authorization: Bearer EXAMPLE.token_1=' 'Authorization: Bearer [REDACTED]' \
  "scrub: Bearer token"
scrub_is 'jwt ey''JEXAMPLE.ey''JEXAMPLE.EXAMPLE end' \
  'jwt [REDACTED] end' "scrub: JWT"
scrub_is 'password=EXAMPLEEXAMPLE' 'password=[REDACTED]' \
  "scrub: password=value"
scrub_is '{"api_key": "EXAMPLE1"}' '{"api_key": "[REDACTED]"}' \
  "scrub: JSON api_key value"
scrub_is 'SECRET: EXAMPLEvalue' 'SECRET: [REDACTED]' \
  "scrub: SECRET: value (case-insensitive key)"
scrub_is 'Token=EXAMPLE1' 'Token=[REDACTED]' \
  "scrub: Token=value"
scrub_is 'api-key: EXAMPLE78' 'api-key: [REDACTED]' \
  "scrub: api-key: value"
scrub_is 'aws_secret_access_key=EXAMPLE1234' 'aws_secret_access_key=[REDACTED]' \
  "scrub: keyword with a suffix (aws_secret_access_key=)"
scrub_is 'SECRET_KEY=EXAMPLE9' 'SECRET_KEY=[REDACTED]' \
  "scrub: SECRET_KEY= value"
scrub_is 'PRIVATE_KEY=abc' 'PRIVATE_KEY=[REDACTED]' \
  "scrub: PRIVATE_KEY= value"
scrub_is 'pwd=EXAMPLE' 'pwd=[REDACTED]' "scrub: pwd= value"
scrub_is 'db credentials: EXAMPLE' 'db credentials: [REDACTED]' "scrub: credentials: value"
scrub_is '"password": "EXAMPLE EXAMPLE"' '"password": "[REDACTED]"' \
  "scrub: quoted value redacted up to the closing quote"
scrub_is "'token': 'abc def'" "'token': '[REDACTED]'" \
  "scrub: single-quoted value redacted up to the closing quote"
scrub_is 'postgres://alice:EXAMPLE@db.example:5432/app' 'postgres://[REDACTED]@db.example:5432/app' \
  "scrub: scheme://user:pass@ userinfo"
scrub_is 'Authorization: Basic RVhBTVBMRUVYQU1QTEU=' 'Authorization: Basic [REDACTED]' \
  "scrub: Basic auth token"
scrub_is 'token gh''u_EXAMPLEEXAMPLEEXAMPLE0123 and gh''o_EXAMPLEEXAMPLEEXAMPLE0123' \
  'token [REDACTED] and [REDACTED]' "scrub: GitHub gh[pousr]_ token prefixes"
scrub_is 'key AK''IAIOSFODNN7EXAMPLE and AS''IAIOSFODNN7EXAMPLE' 'key [REDACTED] and [REDACTED]' \
  "scrub: AWS AKIA and ASIA key ids"
scrub_is 'slack xo''xb-EXAMPLE-EXAMPLE' 'slack [REDACTED]' "scrub: Slack xox token"
scrub_is 'maps AI''zaEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE' 'maps [REDACTED]' "scrub: Google AI''za key"
scrub_is 'stripe sk_''live_EXAMPLEEXAMPLE' 'stripe [REDACTED]' "scrub: Stripe sk_''live_ key"
scrub_is 'stripe sk_test_abcdefghijklmnop1234' 'stripe [REDACTED]' "scrub: Stripe sk_test_ key"

pem_in="$(printf 'before\n-----BEGIN RSA PRIV''ATE KEY-----\nEXAMPLEEXAMPLE\n-----END RSA PRIV''ATE KEY-----\nafter')"
pem_want="$(printf 'before\n[REDACTED]\nafter')"
pem_got="$(printf '%s\n' "$pem_in" | handoff_scrub)"
[ "$pem_got" = "$pem_want" ] && ok "scrub: multi-line PEM private key block" \
  || bad "scrub: multi-line PEM private key block (got: $pem_got)"

pem_open="$(printf 'before\n-----BEGIN RSA PRIV''ATE KEY-----\nEXAMPLEEXAMPLE\nmore key\n')"
pem_open_want="$(printf 'before\n[REDACTED]')"
pem_open_got="$(printf '%s\n' "$pem_open" | handoff_scrub)"
[ "$pem_open_got" = "$pem_open_want" ] && ok "scrub: unterminated PEM redacted to EOF" \
  || bad "scrub: unterminated PEM redacted to EOF (got: $pem_open_got)"
scrub_is 'Authorization: token EXAMPLE1234' 'Authorization: token [REDACTED]' \
  "scrub: Authorization: token value"
scrub_is 'AWS_SECRET_ACCESS_KEY abc123def456' 'AWS_SECRET_ACCESS_KEY [REDACTED]' \
  "scrub: keyword followed by a whitespace-separated value"
scrub_is 'DB_PASS=EXAMPLE2' 'DB_PASS=[REDACTED]' "scrub: bare pass after an underscore still redacted"
scrub_is 'PassWord=EXAMPLEx' 'PassWord=[REDACTED]' "scrub: mixed-case keyword (no sed I flag)"
scrub_is 'Tests passed: 14' 'Tests passed: 14' "scrub: 'passed:' is not a credential"
scrub_is 'bypass=on' 'bypass=[REDACTED]' "scrub: 'bypass=' over-redacted (accepted)"
scrub_is 'dbpass=EXAMPLE' 'dbpass=[REDACTED]' "scrub: dbpass= (pass after a letter)"
scrub_is 'mypass=x' 'mypass=[REDACTED]' "scrub: mypass= (pass after a letter)"
scrub_is 'passphrase=x' 'passphrase=[REDACTED]' "scrub: passphrase="
scrub_is 'PASSPHRASE: x' 'PASSPHRASE: [REDACTED]' "scrub: PASSPHRASE: (mixed case)"
scrub_is 'passcode=1234' 'passcode=[REDACTED]' "scrub: passcode="

# Normal text, including words that contain a rule's trigger as a substring
# (risk-management contains sk-, task-runner too, token used as a noun), must be
# untouched.
normal='Refactored the risk-management module; task-runner passed 14 tests; the token count is 42.'
scrub_is "$normal" "$normal" "scrub: normal text left untouched"

# --- opt-in key log and dependency handling -------------------------------
# 34. Without SESSION_HANDOFF_KEY_LOG_REGEX there is no decisions/ folder at all.
keyrepo="$tmp/work/keyrepo"
mkdir -p "$keyrepo"
git -C "$keyrepo" init -q 2>/dev/null
git -C "$keyrepo" checkout -q -b ABC-901_thing 2>/dev/null
mk_transcript "$tmp/t-KA.jsonl" MARKER-KA
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-KA"}' "$tmp/t-KA.jsonl" "$keyrepo" \
  | "$HOOK" >/dev/null 2>&1
[ ! -e "$HOME/.claude/session-log/decisions" ] \
  && ok "key log off by default" || bad "key log off by default"

# 35. With a regex set, a branch starting with a match gets decisions/<match>.md.
mk_transcript "$tmp/t-KB.jsonl" MARKER-KB
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-KB"}' "$tmp/t-KB.jsonl" "$keyrepo" \
  | SESSION_HANDOFF_KEY_LOG_REGEX='[A-Z]+-[0-9]+' "$HOOK" >/dev/null 2>&1
[ -s "$HOME/.claude/session-log/decisions/ABC-901.md" ] \
  && grep -q 'MARKER-KB' "$HOME/.claude/session-log/decisions/ABC-901.md" \
  && ok "key log written when regex matches branch start" \
  || bad "key log written when regex matches branch start"

# 36. A branch that does not start with a match gets no key log entry.
git -C "$keyrepo" checkout -q -b plain-branch 2>/dev/null
mk_transcript "$tmp/t-KC.jsonl" MARKER-KC
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-KC"}' "$tmp/t-KC.jsonl" "$keyrepo" \
  | SESSION_HANDOFF_KEY_LOG_REGEX='[A-Z]+-[0-9]+' "$HOOK" >/dev/null 2>&1
[ ! -e "$HOME/.claude/session-log/decisions/plain-branch.md" ] \
  && ! grep -q 'MARKER-KC' "$HOME/.claude/session-log/decisions/ABC-901.md" \
  && ok "key log skipped when branch does not match" \
  || bad "key log skipped when branch does not match"

# 37. Without jq, both hooks exit silently and touch nothing.
# A PATH holding every tool the hooks use except jq. If the jq gate were not
# what exits, the hooks would die earlier (a missing dirname, say) and the test
# would pass for the wrong reason, so the trace must show the jq gate was reached.
nodeps="$tmp/nodeps"
mkdir -p "$nodeps"
for t in dirname cat git sed tr cut grep awk date mkdir rm cp ls find sort head tail wc \
         mktemp mv rmdir sha1sum shasum env stat touch sleep flock; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in /*) ln -sf "$p" "$nodeps/$t" ;; esac
done
[ -z "$(PATH="$nodeps" command -v jq 2>/dev/null)" ] \
  && [ -n "$(PATH="$nodeps" command -v dirname 2>/dev/null)" ] \
  || bad "missing-jq PATH built wrongly"
ls_before="$(find "$HOME/.claude/session-log" -type f 2>/dev/null | wc -l | tr -d ' ')"
trace_end="$(printf '{}' | PATH="$nodeps" /bin/bash -x "$HOOK" 2>&1 >/dev/null)"; rc_end=$?
trace_start="$(printf '{}' | PATH="$nodeps" /bin/bash -x "$START_HOOK" 2>&1 >/dev/null)"; rc_start=$?
out_end="$(printf '{}' | PATH="$nodeps" /bin/bash "$HOOK" 2>/dev/null)"
out_start="$(printf '{}' | PATH="$nodeps" /bin/bash "$START_HOOK" 2>/dev/null)"
ls_after="$(find "$HOME/.claude/session-log" -type f 2>/dev/null | wc -l | tr -d ' ')"
reached_end="$(printf '%s' "$trace_end" | grep -c 'command -v jq')"
reached_start="$(printf '%s' "$trace_start" | grep -c 'command -v jq')"
[ "$rc_end" = 0 ] && [ "$rc_start" = 0 ] && [ -z "$out_end$out_start" ] && [ "$ls_before" = "$ls_after" ] \
  && [ "$reached_end" -ge 1 ] && [ "$reached_start" -ge 1 ] \
  && ! printf '%s' "$trace_end" | grep -q 'command -v claude' \
  && ok "missing jq: both hooks reach the jq gate and exit 0 silently" \
  || bad "missing jq: both hooks reach the jq gate and exit 0 silently (rc $rc_end/$rc_start, jq-gate hits $reached_end/$reached_start)"

# 38. The injected context frames the note as untrusted, past-session data and
#     tells the model to verify paths and branches before relying on them.
frame_dir="$tmp/work/framing"
mkdir -p "$frame_dir"
mk_transcript "$tmp/t-FR.jsonl" MARKER-FR
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-FR"}' "$tmp/t-FR.jsonl" "$frame_dir" \
  | "$HOOK" >/dev/null 2>&1
frame="$(printf '{"cwd":"%s","source":"startup"}' "$frame_dir" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if printf '%s' "$frame" | grep -q 'MARKER-FR' \
  && printf '%s' "$frame" | grep -q 'not an instruction' \
  && printf '%s' "$frame" | grep -q 'untrusted data' \
  && printf '%s' "$frame" | grep -q 'verify that it still exists'; then
  ok "injected context marked as untrusted, verify-before-use"
else
  bad "injected context marked as untrusted, verify-before-use"
fi

# 39. The nested summarizer call carries the recursion guard and uses the
#     configured model, so its own SessionStart/SessionEnd stay inert.
argslog="$tmp/claude-call.log"
cat > "$tmp/bin/claude" <<ARGS
#!/usr/bin/env bash
cat >/dev/null
printf 'guard=%s/%s args=%s\n' "\${SESSION_HANDOFF_NO_RECURSE:-unset}" "\${CLAUDE_HOOK_NO_RECURSE:-unset}" "\$*" >> "$argslog"
printf '===SUMMARY===\n- x\n===RESUME===\ngo\n'
ARGS
chmod +x "$tmp/bin/claude"
mk_transcript "$tmp/t-MD.jsonl" MARKER-MD
model_dir="$tmp/work/model"
mkdir -p "$model_dir"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-MD"}' "$tmp/t-MD.jsonl" "$model_dir" \
  | "$HOOK" >/dev/null 2>&1
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-ME"}' "$tmp/t-MD.jsonl" "$model_dir" \
  | SESSION_HANDOFF_MODEL=sonnet-test "$HOOK" >/dev/null 2>&1
if grep -q 'guard=1/1 args=-p --model haiku --tools  --strict-mcp-config --no-session-persistence' "$argslog" \
  && grep -q 'guard=1/1 args=-p --model sonnet-test --tools  --strict-mcp-config --no-session-persistence' "$argslog"; then
  ok "summarizer call: both recursion guards set, model from SESSION_HANDOFF_MODEL, tools off, no MCP, no persistence"
else
  bad "summarizer call: both recursion guards set, model from SESSION_HANDOFF_MODEL, tools off, no MCP, no persistence"
fi

# --- T2: end-to-end, planted secret must not reach the summarizer ----------
# The stub records the exact prompt it receives on stdin. A fake key in the
# transcript must be absent from that prompt, and its [REDACTED] stand-in present.
calls_log="$tmp/calls.log"
prompt_log="$tmp/prompt.log"
cat > "$tmp/bin/claude" <<'RECORD'
#!/usr/bin/env bash
printf 'call\n' >> "$CALLS_LOG"
prompt="$(cat)"
printf '%s' "$prompt" >> "$PROMPT_LOG"
tag="$(printf '%s' "$prompt" | grep -oE 'MARKER-[A-Z]+' | head -1)"
printf '===SUMMARY===\n- did %s\n===RESUME===\ncontinue %s\n' "$tag" "$tag"
RECORD
chmod +x "$tmp/bin/claude"
export CALLS_LOG="$calls_log" PROMPT_LOG="$prompt_log"

e2e="$tmp/work/e2e"
mkdir -p "$e2e"
handoff_slugs "$e2e"
edir="$HOME/.claude/session-log/$HANDOFF_SLUG"
: > "$tmp/t-E2E.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"MARKER-E2E deploy with key sk-''ant-api03-EXAMPLEEXAMPLEEXAMPLE"}]}}' >> "$tmp/t-E2E.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"password: EXAMPLEEXAMPLE and more text"}]}}' >> "$tmp/t-E2E.jsonl"
i=0; while [ "$i" -lt 6 ]; do
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"e$i\",\"input\":{}}]}}" >> "$tmp/t-E2E.jsonl"
  i=$((i+1))
done
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' >> "$tmp/t-E2E.jsonl"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-E2E"}' "$tmp/t-E2E.jsonl" "$e2e" \
  | "$HOOK" >/dev/null 2>&1
if [ -s "$prompt_log" ] && ! grep -q 'EXAMPLEEXAMPLEEXAMPLE' "$prompt_log" \
  && ! grep -q 'EXAMPLEEXAMPLE' "$prompt_log" && grep -q '\[REDACTED\]' "$prompt_log" \
  && grep -q 'MARKER-E2E' "$prompt_log"; then
  ok "end-to-end: planted secrets absent from the summarizer prompt"
else
  bad "end-to-end: planted secrets absent from the summarizer prompt"
fi

# A BEGIN with no END fails closed: everything after it is redacted, not printed.
pem_open="$(printf 'before\n-----BEGIN RSA PRIV''ATE KEY-----\nkeep one\nkeep two' | handoff_scrub)"
[ "$pem_open" = "$(printf 'before\n[REDACTED]')" ] \
  && ok "scrub: unterminated BEGIN redacts following lines" \
  || bad "scrub: unterminated BEGIN redacts following lines (got: $pem_open)"

# A BEGIN/END pair inside one prose line redacts only the key span.
scrub_is 'see -----BEGIN RSA PRIV''ATE KEY-----EXAMPLE-----END RSA PRIV''ATE KEY----- for details' \
  'see [REDACTED] for details' "scrub: same-line PEM pair keeps surrounding prose"

# An excerpt that is nothing but a PEM block scrubs down to one [REDACTED] line,
# which must take the same early exit as an empty session: no summarizer call.
pemonly="$tmp/work/pemonly"
mkdir -p "$pemonly"
: > "$tmp/t-PEM.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"-----BEGIN RSA PRIV''ATE KEY-----"}]}}' >> "$tmp/t-PEM.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"-----END RSA PRIV''ATE KEY-----"}]}}' >> "$tmp/t-PEM.jsonl"
i=0; while [ "$i" -lt 6 ]; do
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"p$i\",\"input\":{}}]}}" >> "$tmp/t-PEM.jsonl"
  i=$((i+1))
done
rm -f "$CALLS_LOG"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-PEM"}' "$tmp/t-PEM.jsonl" "$pemonly" \
  | "$HOOK" >/dev/null 2>&1
[ ! -s "$CALLS_LOG" ] && ok "excerpt emptied by the scrub takes the early exit" \
  || bad "excerpt emptied by the scrub takes the early exit"

# --- T5: recursion guards and the off switch stop both hooks ----------------
guard="$tmp/work/guard"
mkdir -p "$guard"
handoff_slugs "$guard"
gdir2="$HOME/.claude/session-log/$HANDOFF_SLUG"
mk_transcript "$tmp/t-GD.jsonl" MARKER-GD
rm -f "$CALLS_LOG"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-GD1"}' "$tmp/t-GD.jsonl" "$guard" \
  | SESSION_HANDOFF_NO_RECURSE=1 "$HOOK" >/dev/null 2>&1
[ ! -s "$CALLS_LOG" ] && [ ! -e "$gdir2/sess-GD1.md" ] \
  && ok "session-end: SESSION_HANDOFF_NO_RECURSE=1 exits before the summarizer" \
  || bad "session-end: SESSION_HANDOFF_NO_RECURSE=1 exits before the summarizer"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-GD2"}' "$tmp/t-GD.jsonl" "$guard" \
  | CLAUDE_HOOK_NO_RECURSE=1 "$HOOK" >/dev/null 2>&1
[ ! -s "$CALLS_LOG" ] && [ ! -e "$gdir2/sess-GD2.md" ] \
  && ok "session-end: CLAUDE_HOOK_NO_RECURSE=1 exits before the summarizer" \
  || bad "session-end: CLAUDE_HOOK_NO_RECURSE=1 exits before the summarizer"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-GD3"}' "$tmp/t-GD.jsonl" "$guard" \
  | SESSION_HANDOFF_DISABLE=1 "$HOOK" >/dev/null 2>&1
[ ! -s "$CALLS_LOG" ] && [ ! -e "$gdir2/sess-GD3.md" ] \
  && ok "session-end: SESSION_HANDOFF_DISABLE=1 exits before the summarizer" \
  || bad "session-end: SESSION_HANDOFF_DISABLE=1 exits before the summarizer"

# Seed one pending handoff normally, then prove the start hook leaves it alone
# under each switch and still serves it afterwards.
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-GD4"}' "$tmp/t-GD.jsonl" "$guard" \
  | "$HOOK" >/dev/null 2>&1
rm -f "$gdir2/.consumed" 2>/dev/null
g_nr="$(printf '{"cwd":"%s","source":"startup"}' "$guard" | CLAUDE_HOOK_NO_RECURSE=1 "$START_HOOK" 2>/dev/null)"
g_dis="$(printf '{"cwd":"%s","source":"startup"}' "$guard" | SESSION_HANDOFF_DISABLE=1 "$START_HOOK" 2>/dev/null)"
g_ok="$(printf '{"cwd":"%s","source":"startup"}' "$guard" | "$START_HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
[ -z "$g_nr" ] && [ -z "$g_dis" ] \
  && ok "session-start: both recursion variables and DISABLE stay silent" \
  || bad "session-start: both recursion variables and DISABLE stay silent"
printf '%s' "$g_ok" | grep -q 'MARKER-GD' \
  && ok "session-start: handoff still pending after the guarded starts" \
  || bad "session-start: handoff still pending after the guarded starts"

# --- lock, slug, sizing and header hardening ------------------------------
# 37. The mkdir lock fallback. A PATH of symlinks without flock forces that path.
nof="$tmp/noflock"
mkdir -p "$nof"
for c in bash sh mkdir rmdir sleep awk date find stat cut tr sed tail cat rm mv mktemp grep ls; do
  p="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$nof/$c"
done
L="$tmp/lock-trap"
( trap - EXIT; PATH="$nof"; . "$SCRIPTS/session-log-common.sh"; handoff_critical() { exit 0; }; handoff_with_lock "$L" 2 ) >/dev/null 2>&1
[ ! -d "$L.d" ] && ok "mkdir lock released when the command exits the shell" \
  || bad "mkdir lock released when the command exits the shell"

# 38. A lock dir older than 60s is a dead holder's leftover: reclaimed at once,
#     not waited out for the full bound (5s here).
S="$tmp/lock-stale"
mkdir "$S.d"
stamp '2020-01-01 00:00:00' "$S.d"
t0="$(date +%s)"
( trap - EXIT; PATH="$nof"; . "$SCRIPTS/session-log-common.sh"; handoff_critical() { :; }; handoff_with_lock "$S" 5 ) >/dev/null 2>&1
el=$(( $(date +%s) - t0 ))
[ "$el" -le 2 ] && [ ! -d "$S.d" ] && ! ls -d "$S.d.stale."* >/dev/null 2>&1 \
  && ok "stale mkdir lock reclaimed (${el}s)" \
  || bad "stale mkdir lock reclaimed (${el}s)"

# 39. A lock file that cannot be opened must not skip the command.
if command -v flock >/dev/null 2>&1; then
  B="$tmp/lock-blocked"
  mkdir "$B"
  ( . "$SCRIPTS/session-log-common.sh"; handoff_critical() { touch "$tmp/ran-unlocked"; }; handoff_with_lock "$B" 1 ) >/dev/null 2>&1
  [ -e "$tmp/ran-unlocked" ] && ok "unopenable lock file: command still runs" \
    || bad "unopenable lock file: command still runs"
else
  ok "flock unavailable — unopenable-lock test skipped"
fi

# 40. Two folders whose paths differ only by `/` vs `-` are different repos.
mkdir -p "$tmp/work/a-b" "$tmp/work/a/b"
handoff_slugs "$tmp/work/a-b"; sa="$HANDOFF_PATH_SLUG"
handoff_slugs "$tmp/work/a/b"; sb="$HANDOFF_PATH_SLUG"
[ "$sa" != "$sb" ] && ok "slug: foo-bar and foo/bar get different folders" \
  || bad "slug: foo-bar and foo/bar get different folders"

# 41. A very long repo path still yields a bounded folder name, and the handoff
#     is written under it rather than failing mkdir on an over-long name.
longdir="$tmp/work/$(head -c 200 /dev/zero | tr '\0' 'L')"
mkdir -p "$longdir"
handoff_slugs "$longdir"
[ "${#HANDOFF_SLUG}" -lt 200 ] && ok "slug: long path capped (${#HANDOFF_SLUG} chars)" \
  || bad "slug: long path capped (${#HANDOFF_SLUG} chars)"
mk_transcript "$tmp/t-LG.jsonl" MARKER-LG
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-LG"}' "$tmp/t-LG.jsonl" "$longdir" \
  | "$HOOK" >/dev/null 2>&1
[ -f "$HOME/.claude/session-log/$HANDOFF_SLUG/sess-LG.md" ] \
  && ok "long repo path: handoff written" || bad "long repo path: handoff written"

# 42. The consumed ledger is trimmed to 200 lines by the start hook (the trim now
#     runs under the lock; the bound itself must still hold).
mk_transcript "$tmp/t-TR.jsonl" MARKER-TR
trwork="$tmp/work/trimproj"
mkdir -p "$trwork"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-TR"}' "$tmp/t-TR.jsonl" "$trwork" | "$HOOK" >/dev/null 2>&1
handoff_slugs "$trwork"
trdir="$HOME/.claude/session-log/$HANDOFF_SLUG"
i=0
: > "$trdir/.consumed"
while [ "$i" -lt 250 ]; do printf 'digest%03d\n' "$i" >> "$trdir/.consumed"; i=$((i+1)); done
printf '{"cwd":"%s","source":"startup"}' "$trwork" | "$START_HOOK" >/dev/null 2>&1
[ "$(wc -l < "$trdir/.consumed" | tr -d ' ')" -le 200 ] \
  && ok "consumed ledger trimmed to 200 lines" || bad "consumed ledger trimmed to 200 lines"

# 43. SUMMARY_TIMEOUT above 50 is clamped, since hooks.json allows 60s in all.
real_timeout="$(command -v timeout 2>/dev/null || true)"
if [ -n "$real_timeout" ]; then
  tlog="$tmp/timeout-args"
  cbin="$tmp/clampbin"
  mkdir -p "$cbin"
  cat > "$cbin/timeout" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$tlog"
shift
exec "$real_timeout" "\$@"
STUB
  chmod +x "$cbin/timeout"
  mk_transcript "$tmp/t-TO.jsonl" MARKER-TO
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-TO"}' "$tmp/t-TO.jsonl" "$work" \
    | SESSION_HANDOFF_SUMMARY_TIMEOUT=999 PATH="$cbin:$PATH" "$HOOK" >/dev/null 2>&1
  [ "$(head -1 "$tlog" 2>/dev/null)" = 50 ] && ok "summarizer timeout clamped to 50" \
    || bad "summarizer timeout clamped to 50 (got: $(head -1 "$tlog" 2>/dev/null))"
else
  ok "timeout(1) unavailable — timeout clamp test skipped"
fi

# 44. A session_id that is empty after parsing is filed as `unknown`.
mk_transcript "$tmp/t-UN.jsonl" MARKER-UN
printf '{"transcript_path":"%s","cwd":"%s","session_id":""}' "$tmp/t-UN.jsonl" "$work" | "$HOOK" >/dev/null 2>&1
[ -f "$dir/unknown.md" ] && grep -q 'MARKER-UN' "$dir/unknown.md" \
  && ok "empty session_id filed as unknown" || bad "empty session_id filed as unknown"

# 45. A newline or `-->` in session_id must not escape the header comment.
mk_transcript "$tmp/t-NL.jsonl" MARKER-NL
printf '{"transcript_path":"%s","cwd":"%s","session_id":"evil-->\\nINJ"}' "$tmp/t-NL.jsonl" "$work" \
  | "$HOOK" >/dev/null 2>&1
nlf="$dir/evil--__INJ.md"
if [ -f "$nlf" ] && grep -qxF '<!-- session: evil--&gt;INJ -->' "$nlf" && ! grep -q '^INJ' "$nlf"; then
  ok "session_id newline and --> neutralised in header"
else
  bad "session_id newline and --> neutralised in header"
fi

# 46. A branch name containing --> must not escape the branch header comment.
brepo="$tmp/work/branchrepo"
mkdir -p "$brepo"
git -C "$brepo" init -q 2>/dev/null
git -C "$brepo" checkout -q -b 'feat-->INJB' 2>/dev/null
mk_transcript "$tmp/t-BR.jsonl" MARKER-BR
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-BR"}' "$tmp/t-BR.jsonl" "$brepo" \
  | "$HOOK" >/dev/null 2>&1
handoff_slugs "$brepo"
brf="$HOME/.claude/session-log/$HANDOFF_SLUG/sess-BR.md"
if [ -f "$brf" ] && grep -qxF '<!-- branch: feat--&gt;INJB -->' "$brf"; then
  ok "branch --> neutralised in header"
else
  bad "branch --> neutralised in header"
fi

# 47. The key log heading uses the neutralised session id, not the raw one.
krepo="$tmp/work/keyrepo2"
mkdir -p "$krepo"
git -C "$krepo" init -q 2>/dev/null
git -C "$krepo" checkout -q -b ABC-902_keyx 2>/dev/null
mk_transcript "$tmp/t-KL.jsonl" MARKER-KL
printf '{"transcript_path":"%s","cwd":"%s","session_id":"sess-->KL"}' "$tmp/t-KL.jsonl" "$krepo" \
  | SESSION_HANDOFF_KEY_LOG_REGEX='[A-Z]+-[0-9]+' "$HOOK" >/dev/null 2>&1
kf="$HOME/.claude/session-log/decisions/ABC-902.md"
if [ -f "$kf" ] && grep -qF 'session sess--&gt;KL (' "$kf" && ! grep -qF 'sess-->KL' "$kf"; then
  ok "key log heading neutralises session id"
else
  bad "key log heading neutralises session id"
fi

# 48. The mkdir lock wrapper hands back the caller's own EXIT trap.
cat > "$tmp/trapcheck.sh" <<TC
trap 'echo CALLER_TRAP' EXIT
. "$SCRIPTS/session-log-common.sh"
handoff_critical() { :; }
handoff_with_lock "$tmp/lock-keep" 2
trap -p EXIT
TC
tout="$(PATH="$nof" "$nof/bash" "$tmp/trapcheck.sh" 2>/dev/null)"
if printf '%s\n' "$tout" | grep -qxF "trap -- 'echo CALLER_TRAP' EXIT" \
  && printf '%s\n' "$tout" | grep -qxF 'CALLER_TRAP'; then
  ok "lock wrapper restores the caller's EXIT trap"
else
  bad "lock wrapper restores the caller's EXIT trap (got: $tout)"
fi

# 49. The start hook takes its repo lock once: claim and trim share one wait.
flog="$tmp/flock-calls"
: > "$flog"
fbin="$tmp/flockbin"
mkdir -p "$fbin"
real_flock="$(command -v flock 2>/dev/null || true)"
if [ -n "$real_flock" ]; then
  cat > "$fbin/flock" <<STUB
#!/usr/bin/env bash
echo call >> "$flog"
exec "$real_flock" "\$@"
STUB
  chmod +x "$fbin/flock"
  printf '{"cwd":"%s","source":"startup"}' "$trwork" | PATH="$fbin:$PATH" "$START_HOOK" >/dev/null 2>&1
  calls="$(wc -l < "$flog" | tr -d ' ')"
  [ "$calls" -eq 1 ] && ok "start hook takes the lock once" \
    || bad "start hook takes the lock once (flock calls: $calls)"
else
  ok "flock unavailable — single-lock test skipped"
fi

# 50. The marketplace manifest carries a top-level description.
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.description // empty' "$HERE/../.claude-plugin/marketplace.json")" \
    = "Session handoff plugin for Claude Code" ] \
    && ok "marketplace.json has top-level description" \
    || bad "marketplace.json has top-level description"
else
  ok "jq unavailable — marketplace description test skipped"
fi

exit $fail
