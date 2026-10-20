# session-handoff

A Claude Code plugin that carries context from one session to the next. When a
session closes, it writes a short summary and a copy-pasteable resume prompt for
that repo. When the next session starts in the same repo, it receives that note
as context, once.

## How it works

```
 SessionEnd (session closes)
   |
   v
 transcript -> keep user/assistant text, drop tool payloads
   |
   v
 scrub credential-shaped text (regex, best effort)
   |
   v
 claude -p --model $SESSION_HANDOFF_MODEL   <- nested headless summarizer
   |
   v
 <DIR>/<repo-path>@<branch>/<session-id>.md   (+ NEXT_PROMPT.md, global log)

 SessionStart (new session starts)
   |
   v
 claim the newest unconsumed handoff for this repo (all branches)
   |
   v
 retire older handoffs, list them by title
   |
   v
 emit as SessionStart additionalContext (framed as untrusted, wait for the user)
```

A session that did not touch at least `SESSION_HANDOFF_MIN_TOOL_CALLS` tools is
treated as a one-shot question and gets no summarizer call and no handoff. A
session that was served a handoff always passes it on, even if it did little
work, so the thread is not lost.

## Requirements

- bash
- `jq`
- `claude` CLI on PATH
- Optional, with fallbacks: `flock` (serializes concurrent writes; without it
  a `mkdir` lock is used, with a bounded wait), and `timeout` or `gtimeout`
  (bounds the summarizer call; without either, a pure-bash watcher enforces
  the same limit)

If `jq` or `claude` is missing, the hooks exit silently and do nothing. Hooks
never block session start or close.

Tested on Linux (GNU coreutils). macOS is supported through its BSD tools
(`shasum`, `stat -f`). BSD `find` has no `-printf`, so the mtime falls back to
whole seconds there, and ordering between handoffs written within the same
second cannot be resolved.

## Install

```
/plugin marketplace add EhsanMo/claude-session-handoff
/plugin install session-handoff@session-handoff
```

The first command takes this repository, which contains
`.claude-plugin/marketplace.json`. `session-handoff` is the marketplace name.

If you already have your own `SessionStart`/`SessionEnd` hooks that run these
scripts, remove them. Running both makes every session write and resume twice.

## Configuration

All settings are environment variables. None is required.

| Variable | Default | Purpose |
|---|---|---|
| `SESSION_HANDOFF_DIR` | `$HOME/.claude/session-log` | Where handoff files are written |
| `SESSION_HANDOFF_MODEL` | `haiku` | Model used by the nested `claude -p` summarizer |
| `SESSION_HANDOFF_MAX_AGE_DAYS` | `14` | Handoffs older than this are ignored |
| `SESSION_HANDOFF_MIN_TOOL_CALLS` | `5` | Sessions with fewer tool calls get no handoff (`0` keeps every session) |
| `SESSION_HANDOFF_EXCERPT_BYTES` | `14000` | Size cap on the transcript text sent to the summarizer; the tail is kept |
| `SESSION_HANDOFF_SUMMARY_TIMEOUT` | `45` | Seconds before the summarizer call is abandoned. Capped at `50`, inside the 60-second hook timeout |
| `SESSION_HANDOFF_KEY_LOG_REGEX` | unset (off) | Opt-in. A `grep -E` pattern matched at the start of the branch name. When it matches, the summary is also appended to `<DIR>/decisions/<match>.md`. Example: `[A-Z]+-[0-9]+` for ticket keys |
| `SESSION_HANDOFF_DISABLE` | unset | Set to `1` to turn both hooks off completely. Checked first, so nothing is read or written |
| `SESSION_HANDOFF_NO_RECURSE` | unset | Internal. Set on the nested summarizer call. Either this or `CLAUDE_HOOK_NO_RECURSE` set to `1` makes both hooks exit at once. Do not set it yourself |
| `CLAUDE_HOOK_NO_RECURSE` | unset | Internal, same effect as `SESSION_HANDOFF_NO_RECURSE`. The nested summarizer call sets both |
| `SESSION_HANDOFF_CLAIM_DELAY` | unset | Test seam only. Widens the claim window in the test suite |

Numeric settings that are not whole numbers fall back to their defaults.

## Where files live

Under `<DIR>` (default `~/.claude/session-log`):

- `<slug>.md`: append-only log of every summary for the repo and branch
- `<slug>/<session-id>.md`: the resume prompt of each session. This is what
  SessionStart reads. The newest 20 are kept.
- `<slug>/NEXT_PROMPT.md`: a copy of the most recently closed session's file,
  for a human to look at
- `<slug>/.consumed`: digests of handoffs already injected (last 200 kept)
- `.claimed/`: short-lived markers linking a running session to the handoff it
  was served. A marker is cleared once that session's successor handoff is on
  disk, so a hook killed part way keeps its claim.

`<slug>` is the repo's path relative to `$HOME`, with `/` mapped to `-`, then
capped to its last 80 characters and suffixed with an 8-character hash of the full
path, then `@<branch>`. The hash keeps `foo-bar` and `foo/bar` apart, and the cap
keeps the folder name well inside the filesystem's 255-byte limit. Two checkouts
with the same folder name do not share handoffs.

## Performance

Measured on a Linux x86_64 workstation (kernel 6.8, Claude Code 2.1.300) on
2026-10-20. Both hook scripts were run directly with the hook's stdin JSON, and
each timing is wall-clock (`date +%s.%N`). Every case ran 3 times and the median
is shown. The summarizer case is a real `claude -p --model haiku` call, so its
time is mostly network and API latency. The numbers are indicative, not a
benchmark.

| Case | Median of 3 |
|---|---|
| SessionEnd, real summarizer, ~20 KB transcript | 9.1 s |
| SessionEnd, real summarizer, ~200 KB transcript | 9.9 s |
| SessionEnd, real summarizer, ~2 MB transcript | 9.4 s |
| SessionEnd, skipped by the tool-call gate (2 tool calls) | 0.04 s |
| SessionStart, a handoff is pending | 0.04 s |
| SessionStart, none pending | 0.02 s |
| Test suite (`bash tests/test-session-handoff.sh`) | 21.1 s, 117 ok, 0 failed |

- **Summarizer input is capped.** `SESSION_HANDOFF_EXCERPT_BYTES` defaults to
  14000 and keeps the tail of the transcript text. All three transcript sizes
  were sent as the same excerpt (about 14 KB plus the omission marker), so the
  summarizer's cost does not grow past the cap. Even the 20 KB transcript
  exceeded it once tool payloads were stripped.
- **Injected context.** A typical note of 621 bytes becomes 1,123 bytes of
  `additionalContext` once the framing is added, about 280 tokens (bytes / 4).
- **Extra cost per session (estimate).** A session that passes the gate makes
  one `claude -p` call at SessionEnd. SessionStart makes none. The captured
  summarizer prompt was 14,626 bytes, about 3,650 input tokens (bytes / 4). Of
  that, about 3,510 tokens are the excerpt and about 150 are the prompt template.
  A skipped session makes no call.
- **Timeouts.** `hooks/hooks.json` allows 10 s for SessionStart and 60 s for
  SessionEnd. The summarizer call defaults to `SESSION_HANDOFF_SUMMARY_TIMEOUT`
  (45 s) and is clamped to 50 s, inside the SessionEnd limit.

## Privacy

- Transcript text from each session is sent to the Claude model, through a
  nested `claude -p` call, to produce the summary. This happens on every session
  that passes the tool-call gate.
- Before it is sent, the transcript text is passed through best-effort regex
  scrubbing, and the summary is scrubbed again before it is written. Each
  match becomes `[REDACTED]`; line structure is kept. The rules:
  - `sk-` and `sk-ant-` keys (20+ characters after the prefix)
  - `sk_live_` and `sk_test_` keys (Stripe)
  - AWS access key IDs with the `AKIA` or `ASIA` prefix
  - GitHub tokens `gh[pousr]_` and fine-grained `github_pat_`
  - GitLab `glpat-` tokens
  - Slack `xox[abprs]-` tokens
  - Google `AIza` keys (39 characters)
  - `Bearer <token>` and `Basic <base64>` authorization values
  - JWTs (three base64url segments, the first two starting `eyJ`)
  - `scheme://user:pass@` URLs, which keep the scheme and host and redact the
    userinfo to `scheme://[REDACTED]@`
  - PEM private key blocks, `-----BEGIN ... PRIVATE KEY-----` through the
    matching END line, including `PGP PRIVATE KEY BLOCK`. A BEGIN line with no
    END line is redacted to the end of the text: failing closed is preferred.
  - `Authorization: token <value>` and `token <value>`, where the value is 8 or
    more token characters. Prose such as `token validation` is matched too, so
    this rule over-redacts on purpose.
  - An uppercase environment-style key followed by whitespace and a value of 8 or
    more characters, for example `AWS_SECRET_ACCESS_KEY abc123...`. Keys ending
    in `PASSWORD`, `PASSWD`, `PWD`, `SECRET`, `TOKEN`, `API_KEY`, `CREDENTIAL(S)`
    or `PRIVATE_KEY` are matched. Lowercase keys are not.
  - A keyword followed by `=` or `:`, with optional letters, digits or
    underscores in between. Keywords (matched in any case): `password`,
    `passwd`, `pass`, `pwd`, `secret`, `token`, `api_key` / `api-key`,
    `credential(s)`, `private_key`.
    So `aws_secret_access_key=`, `SECRET_KEY=` and `PRIVATE_KEY=` all match.
    A bare `pass` must follow a non-letter and may only be followed by `_` and
    more characters, so `DB_PASS=` matches while `bypass=on` and
    `Tests passed: 14` do not.
    A quoted value is redacted up to its closing quote, so
    `"password": "correct horse"` becomes `"password": "[REDACTED]"`.

  This is not a guarantee. Unusual formats, secrets split across lines, and
  secrets with no keyword in front of them will pass through.
- Transcript text can also contain the summarizer's delimiter line. Those are
  removed before the excerpt is sent, so a transcript cannot close the block
  it is placed in.
- The summaries and resume prompts are stored unencrypted under `SESSION_HANDOFF_DIR`.
  Anyone who can read that folder can read them.
- The hooks set `umask 077`, so new files and folders are readable by your
  user only. Existing folders keep their permissions.

To stop everything without uninstalling, set `SESSION_HANDOFF_DISABLE=1` in
the environment the hooks run in. That turns both hooks off completely.
Uninstalling is `/plugin uninstall session-handoff`, or disabling the plugin in
`/plugin`.

To reduce how many summaries are written rather than stop them all, raise
`SESSION_HANDOFF_MIN_TOOL_CALLS`. That gate only applies to new sessions: a
session that was served a handoff always passes it on, so raising the gate does
not stop a chain already in progress. To remove stored data, delete
`SESSION_HANDOFF_DIR` (default `~/.claude/session-log`).

## Tests

```
bash tests/test-session-handoff.sh
```

The suite runs in a temporary HOME and does not touch `~/.claude`. It uses a
stub `claude` and needs `jq`.

## License

MIT. See `LICENSE`.
