# fm-spectrum: private captain<->firstmate iMessage channel (slice 1)

fm-spectrum is a private, two-way iMessage channel between the captain and
firstmate, built on `spectrum-ts`'s iMessage **local mode**. Local mode reads
`~/Library/Messages/chat.db` directly and sends via `osascript`-driven
Messages.app - **zero Photon cloud involvement, no account, no network call
beyond iMessage's own Apple-to-Apple transport.** See
`data/spectrum-local-v2/report.md` for the source-verified design and
`data/spectrum-scout-s5/report.md` for the broader X-mode-mirroring rationale
this implementation follows.

It ships inside this repo for every user but is **inert until opted in**,
exactly like X mode (AGENTS.md section 14): a user who never sets
`SPECTRUM_SELF_HANDLE` sees zero behavior change.

## Slice 1 scope (this PR)

Built: the bridge process, outbound escalations (`fm-spectrum-notify.sh`),
dry-run preview, `.env` gating, and bridge liveness/health checking.

Deferred to a follow-up slice: wiring inbound messages into firstmate's wake
queue and a `spectrum-respond` skill to act on them. The bridge already writes
inbound messages to `state/spectrum-inbox/` in this slice (cheap, and it sets
up the next slice), but nothing consumes that inbox yet.

## Identities

- **firstmate's own iMessage identity:** `lily.lotuscloud@gmail.com` - the
  Apple ID Messages.app on this Mac mini is (or will be) signed into.
- **the captain:** reachable at **two** handles, either of which counts as the
  captain - `tharshan09@gmail.com` and `+12262246894`. Both are allowlisted
  for inbound (a message from either is honored); either works as an outbound
  target (verified: sending from `lily.lotuscloud@gmail.com` to either handle
  works). `SPECTRUM_CAPTAIN_HANDLE` lists both, comma-separated (see
  Config below).

**One manual prerequisite for the captain:** switch Messages.app on the Mac
mini to be signed into `lily.lotuscloud@gmail.com` (keep `tharshan09@gmail.com`
signed in wherever it's needed for Xcode/dev work - just not in the Messages.app
session the bridge drives). Until that switch happens, do not run the bridge
live; dry-run needs no live account at all (see below).

Two macOS TCC (Transparency, Consent & Control) grants are also needed on
whatever machine runs the bridge, both one-time interactive approvals:

- **Full Disk Access** for the process running the bridge (inbound: reads
  `chat.db`).
- **Automation -> Messages** (outbound: `osascript` sending AppleEvents to
  Messages.app). The first live send from a new responsible process triggers a
  one-time "…wants to control Messages" prompt; approve it once from a GUI
  login session. See `data/spectrum-local-v2/report.md` section 3 for the full
  detail (including why a headless context hangs on this prompt for ~2
  minutes and how to avoid that).

## Config (`.env`, gitignored)

| Var | Required | Meaning |
| --- | --- | --- |
| `SPECTRUM_SELF_HANDLE` | yes | The iMessage handle the bridge sends as. **Presence of this var is the whole activation signal** - absent, every `fm-spectrum-*` script is a hard no-op (exit 0), mirroring `FMX_PAIRING_TOKEN`'s X-mode activation contract. |
| `SPECTRUM_CAPTAIN_HANDLE` | yes (once `SPECTRUM_SELF_HANDLE` is set) | A **comma-separated set** of the captain's iMessage handles, e.g. `tharshan09@gmail.com,+12262246894`. Every listed handle is honored on inbound (the bridge's sender allowlist - a message from any of them is treated as the captain; anything else is logged and dropped, never stashed). The **first** listed handle is also the default outbound target when neither `SPECTRUM_TARGET_HANDLE` nor an explicit `--target` is given. |
| `SPECTRUM_TARGET_HANDLE` | no | Override the default outbound target (otherwise the first handle in `SPECTRUM_CAPTAIN_HANDLE`). Either handle works as a target; this just picks which one `fm-spectrum-notify.sh` defaults to when no `--target` is given. |
| `SPECTRUM_DRY_RUN` | no | Truthy (anything but unset/empty/`0`/`false`/`no`/`off`) puts outbound sends in preview mode: nothing is sent, the would-send payload is recorded to `state/spectrum-outbox/`, and a `DRY RUN` summary prints to stderr. Mirrors `FMX_DRY_RUN`. |
| `SPECTRUM_ENV_FILE` | no | Point a direct client invocation at a different `.env`-style file (testing only; normal use reads `$FM_HOME/.env`). |
| `SPECTRUM_BRIDGE_STALE_SECS` | no | Seconds before `fm-spectrum-status.sh` calls the bridge's liveness beacon stale. Default `90` (the bridge touches its beacon roughly every 20s, so this gives several missed cycles of grace). |

No Photon `projectId`/`projectSecret` is ever required - local mode has an
explicit no-credentials construction path (see the design report, section 1).

## Components

```
bin/fm-spectrum-lib.sh          shared config resolution (sourced only)
bin/fm-spectrum-notify.sh       outbound: drop one escalation for the bridge to send
bin/fm-spectrum-status.sh       health check: reads the bridge's liveness beacon
bin/fm-spectrum-bridge          launcher: gates config, execs the Node bridge
bin/spectrum-bridge/            the Node bridge itself (package.json + index.js)
state/spectrum-inbox/           inbound messages the bridge writes (unconsumed this slice)
state/spectrum-outbox/          outbound drop files fm-spectrum-notify.sh writes,
                                 the bridge drains
state/.spectrum-bridge-beat     liveness beacon the bridge touches periodically
```

`state/`, `data/`, and `.env` are already gitignored wholesale in this repo, so
no `.gitignore` changes were needed for the new `spectrum-*` state paths or
`SPECTRUM_*` env vars.

### The bridge (`bin/fm-spectrum-bridge` + `bin/spectrum-bridge/`)

`bin/fm-spectrum-bridge` is a bash launcher (not `.sh`-suffixed, so it isn't
swept into the repo's `shellcheck bin/*.sh` lint - it's still plain bash). It
owns all `.env`/config resolution and gating, exactly like every other
`fm-spectrum-*`/`fm-x-*` script, then `exec`s the actual long-running logic:
`bin/spectrum-bridge/index.js`, a small Node script that never reads `.env`
itself - it only sees the resolved environment the launcher exports
(`FM_SPECTRUM_STATE`, `FM_SPECTRUM_SELF`, `FM_SPECTRUM_CAPTAIN`,
`FM_SPECTRUM_DRY`).

The bridge:
1. Constructs `Spectrum({ providers: [imessage.config({ local: true })] })` -
   no Photon credentials, per the design report.
2. Tails `app.messages`; for each inbound `[space, message]` whose sender
   matches any handle in `SPECTRUM_CAPTAIN_HANDLE` (case-insensitive), atomically
   writes `state/spectrum-inbox/<message.id>.json` (space id/guid, sender,
   text, content type, timestamp). Non-allowlisted senders are logged and
   dropped.
3. Polls `state/spectrum-outbox/` every 2s for JSON drop files
   (`{id, target, text, ts, dry_run}`, written by `fm-spectrum-notify.sh`) and,
   unless dry-run (the bridge's own `SPECTRUM_DRY_RUN`, or the file's own
   `dry_run: true`), sends via `space.get(target).send(text)`. Sent (or
   stubbed) files are removed; a failed live send is left in place so a
   restart can retry rather than silently dropping a captain-bound
   escalation.
4. Touches `state/.spectrum-bridge-beat` every 15s.

**Dependencies are pinned but not installed by this PR.** `bin/spectrum-bridge/package.json`
pins `spectrum-ts@8.2.1` and `@spectrum-ts/imessage@8.2.1` - the exact versions
the design report source-verified. Before running the bridge live, install
them:

```sh
(cd bin/spectrum-bridge && npm install)
```

If those dependencies are missing, the bridge fails immediately with a clear
message telling you to run the install above, instead of limping along in a
half-working state. That is the expected, tested behavior in any environment
that hasn't run the install (including CI, which cannot exercise the real
macOS-only local iMessage transport anyway).

### Starting / stopping the bridge

This slice does not wire the bridge into firstmate's watcher/supervision
backbone (that's the follow-up slice, alongside inbound wake-queue wiring).
For now, start it by hand, backgrounded, from a GUI login session (needed for
the one-time Automation prompt):

```sh
nohup bin/fm-spectrum-bridge >> state/spectrum-bridge.log 2>&1 &
```

Stop it with a normal signal (`kill <pid>`, or `Ctrl-C` if run in the
foreground) - it handles `SIGINT`/`SIGTERM` by calling `app.stop()` before
exiting.

Check its health any time with:

```sh
bin/fm-spectrum-status.sh
```

which reports one of `disabled` (not configured - normal resting state),
`healthy` (beacon fresh), `stale` (beacon older than
`SPECTRUM_BRIDGE_STALE_SECS`, default 90s - the bridge may be hung or
crashed), or `dead` (configured but no beacon file at all - never started, or
torn down). `disabled` and `healthy` exit 0; `stale` and `dead` exit 1, so a
future poll shim can script off it directly.

### Sending an escalation (`fm-spectrum-notify.sh`)

```sh
bin/fm-spectrum-notify.sh --text-file <path>                       # default target
bin/fm-spectrum-notify.sh --target <handle-or-space> --text-file <path>
bin/fm-spectrum-notify.sh -                                         # read from stdin, default target
bin/fm-spectrum-notify.sh "<text>"                                  # quick manual use, default target
```

The target is optional: omitted, it defaults to `SPECTRUM_TARGET_HANDLE`, or
else the first handle in `SPECTRUM_CAPTAIN_HANDLE` - either works, since both
listed captain handles are reachable and verified. Pass `--target` (or a
leading positional target, kept for back-compat, e.g.
`fm-spectrum-notify.sh tharshan09@gmail.com --text-file <path>`) to send to a
specific handle instead.

Like `fm-x-reply.sh`, message text is never inlined into a shell argument by
firstmate itself - always `--text-file` or stdin, so PR titles, diff
summaries, etc. can't trip shell quoting. It never talks to the bridge
directly; it atomically drops a JSON record into `state/spectrum-outbox/` for
the bridge to pick up and send. That keeps this script a fast, dependency-light
one-shot exactly like the X-mode outbound clients, and means a dry-run works
even with no bridge process running at all.

## Dry-run: the acceptance path for this PR

`SPECTRUM_DRY_RUN=1` makes `fm-spectrum-notify.sh` write the outbox record
with `dry_run: true` and print a `DRY RUN` summary to stderr, without needing a
live Messages account, the bridge running, or even `npm install` having been
run:

```sh
printf 'PR is ready for review: https://github.com/example/repo/pull/1' > /tmp/msg.txt
SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
SPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com \
SPECTRUM_DRY_RUN=1 \
  bin/fm-spectrum-notify.sh tharshan09@gmail.com --text-file /tmp/msg.txt
# -> fm-spectrum-notify: DRY RUN - would send to tharshan09@gmail.com (recorded: state/spectrum-outbox/<id>.json): PR is ready...
```

If the bridge is running with its own `SPECTRUM_DRY_RUN` set, or picks up a
file whose own `dry_run` is `true` (as above), it stubs the send the same way:
logs what it would have sent and never calls `osascript`. That's also the way
to sanity-check the bridge's Spectrum wiring end to end without ever emitting a
real message.

**Live end-to-end (a real bridge process, a real send) is deferred pending the
captain's Messages-account switch** described above, and was not exercised in
this PR.
