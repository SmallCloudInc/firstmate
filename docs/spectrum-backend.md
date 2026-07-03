# fm-spectrum: private captain<->firstmate iMessage channel

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

## Slice 1 scope

Built: the bridge process, outbound escalations (`fm-spectrum-notify.sh`),
dry-run preview, `.env` gating, and bridge liveness/health checking. The
bridge already wrote inbound messages to `state/spectrum-inbox/` in this
slice (cheap, and it set up the next slice), but nothing consumed that inbox
yet, and the bridge had to be started by hand.

## Slice 2 scope (this PR): always-on, two-way

Slice 2 closes the loop slice 1 left open, mirroring X mode's design
(AGENTS.md section 14) closely rather than inventing a parallel shape:

- **Inbound wiring**: a check shim (`state/spectrum-watch.check.sh`, generated
  by bootstrap exactly like X mode's `state/x-watch.check.sh`) rides the
  existing `state/*.check.sh` watcher mechanism, so a pending inbound message
  produces a `check:` wake - no edits to `bin/fm-watch.sh`,
  `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh`, or the afk daemon.
- **`spectrum-respond` skill** (`.agents/skills/spectrum-respond/`): drains
  every `state/spectrum-inbox/*.json` on that wake, classifies each message,
  acts on it, replies, and clears the inbox file - the private-channel
  analogue of `fmx-respond`.
- **Auto-push escalations**: `bin/fm-spectrum-escalate.sh` pushes a
  captain-facing escalation (AGENTS.md section 9) to the private channel when
  the channel is configured AND the captain is away (`state/.afk` present).
- **Always-on bridge supervision**: `bin/fm-spectrum-ensure-bridge.sh` makes
  the bridge idempotently self-starting and self-healing, invoked both at
  session-start bootstrap and on every watcher check cycle via the same
  `state/spectrum-watch.check.sh` shim used for inbound.

See "Inbound wiring", "Starting / stopping the bridge", and "Auto-push
escalations" below for the full detail on each piece.

## Identities

- **firstmate's own iMessage identity:** `lily.lotuscloud@gmail.com` - the
  Apple ID Messages.app on this Mac mini is (or will be) signed into.
- **the captain:** reachable at **two** handles, either of which counts as the
  captain - `tharshan09@gmail.com` and `+12262246894`. Both are allowlisted
  for inbound (a message from either is honored); either works as an outbound
  target (verified: sending from `lily.lotuscloud@gmail.com` to either handle
  works). `SPECTRUM_CAPTAIN_HANDLE` lists both, comma-separated (see
  Config below).

**Manual prerequisite for the captain (done):** Messages.app on the Mac mini is
now signed into `lily.lotuscloud@gmail.com` (`tharshan09@gmail.com` stays
available elsewhere for Xcode/dev work - just not in the Messages.app session
the bridge drives). A real outbound send was verified live against this setup
(see "Live verification" below); dry-run remains the no-account-needed path
for iterating on the bridge without live sends.

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
| `SPECTRUM_BRIDGE_STALE_SECS` | no | Seconds before a beacon is considered stale (used by `fm-spectrum-status.sh`'s report AND by `fm-spectrum-ensure-bridge.sh`'s restart decision, via the shared `spectrum_beacon_state()` helper). Default `90` (the bridge touches its beacon roughly every 15s, so this gives several missed cycles of grace). |

No Photon `projectId`/`projectSecret` is ever required - local mode has an
explicit no-credentials construction path (see the design report, section 1).

## Components

```
bin/fm-spectrum-lib.sh          shared config resolution (sourced only)
bin/fm-spectrum-notify.sh       outbound: drop one escalation for the bridge to send
bin/fm-spectrum-escalate.sh     outbound: auto-push a captain-facing escalation,
                                 gated on configured + away (state/.afk)
bin/fm-spectrum-status.sh       health check: reads the bridge's liveness beacon
bin/fm-spectrum-ensure-bridge.sh  supervision: idempotent ensure-started +
                                 stale/dead restart, single-instance locked
bin/fm-spectrum-poll.sh         watcher check-shim body: supervises the bridge
                                 AND surfaces pending inbound as a wake
bin/fm-spectrum-bridge          launcher: gates config, execs the Node bridge
bin/spectrum-bridge/            the Node bridge itself (package.json + index.js)
.agents/skills/spectrum-respond/  agent-only skill: drains state/spectrum-inbox/,
                                 classifies, acts, replies, clears
state/spectrum-inbox/           inbound messages the bridge writes; drained by
                                 the spectrum-respond skill
state/spectrum-outbox/          outbound drop files fm-spectrum-notify.sh /
                                 fm-spectrum-escalate.sh write, the bridge drains
state/.spectrum-bridge-beat     liveness beacon the bridge touches periodically
state/.spectrum-bridge.pid      pidfile fm-spectrum-ensure-bridge.sh tracks the
                                 supervised bridge process by
state/.spectrum-bridge.lock/    mkdir-based mutex serializing concurrent
                                 ensure-started calls
state/spectrum-watch.check.sh   generated by bootstrap when configured: watcher
                                 check shim that execs bin/fm-spectrum-poll.sh
config/spectrum-mode.env        generated by bootstrap: exports
                                 FM_CHECK_INTERVAL=20, sourced by the watcher arm
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
   `dry_run: true`), sends via `imessage(app).space.create(target).send(text)`.
   Sent (or stubbed) files are removed; a failed live send is left in place so
   a restart can retry rather than silently dropping a captain-bound
   escalation.
4. Touches `state/.spectrum-bridge-beat` every 15s.

**The outbound accessor.** The `Spectrum()` app instance itself does not carry
a `.space`/`.im` shortcut - its own keys are just `__providers`, `__internal`,
`config`, `messages`, `stop`, `webhook`, `send`, `edit`, `responding` (confirmed
by introspecting a real constructed instance). The real path is
`@spectrum-ts/core`'s `Platform<Def>` interface: the `imessage` export from
`@spectrum-ts/imessage` (the same object used to build
`imessage.config({...})`) is itself **callable** - `imessage(app)` resolves the
live `PlatformInstance` for that provider on that app, and
`PlatformInstance.space` is the `SpaceNamespace` that actually carries
`.create(handle)` / `.get(id)`, each resolving to a `Space` with `.send()`.
This was verified empirically against the installed `spectrum-ts@8.2.1` +
`@spectrum-ts/imessage@8.2.1`: `imessage(app).space.create('+1...')` resolves a
space whose id matches chat.db's own guid for that handle
(`bin/spectrum-bridge/index.js`'s `resolvePlatformInstance()`, covered by
`tests/fm-spectrum-mode.test.sh`'s `test_bridge_resolves_real_space_accessor`,
which exercises this against the real installed package so a future
spectrum-ts upgrade that moves this API fails a test instead of a live send).

An earlier version of this code guessed `app.im.space.get`/`app.space.get`,
neither of which exists at runtime - a live smoke test caught it (the send
silently never reached `osascript`; no exception outside the guessed-accessor
error). That guess was never exercised against a real `spectrum-ts` install
before this fix.

**Dependencies are pinned and installed for live testing.** `bin/spectrum-bridge/package.json`
pins `spectrum-ts@8.2.1` and `@spectrum-ts/imessage@8.2.1` - the exact versions
the design report source-verified and this fix was verified against.
`bin/spectrum-bridge/node_modules/` is gitignored (reinstall with the command
below); `bin/spectrum-bridge/package-lock.json` is committed for reproducible
installs.

```sh
(cd bin/spectrum-bridge && npm install)
```

If those dependencies are missing, the bridge fails immediately with a clear
message telling you to run the install above, instead of limping along in a
half-working state. That is the expected, tested behavior in any environment
that hasn't run the install (including CI, which cannot exercise the real
macOS-only local iMessage transport anyway).

### Starting / stopping the bridge

As of slice 2 the bridge is firstmate's one always-on long-lived child - you
should not normally need to start it by hand. `bin/fm-spectrum-ensure-bridge.sh`
makes it self-starting and self-healing:

```sh
bin/fm-spectrum-ensure-bridge.sh
```

Safe to call repeatedly and safe to call concurrently:

- **Inert** when spectrum is not configured (hard no-op, exit 0).
- **Idempotent**: a healthy, already-running bridge is left alone (reported as
  `healthy (pid ...)`); a genuinely dead one is started fresh.
- **Single-instance**: an mkdir-based mutex (`state/.spectrum-bridge.lock`)
  serializes concurrent calls, so two callers racing (e.g. bootstrap and a
  watcher check cycle landing at the same moment) never launch two bridge
  processes. A stale lock (its recorded owner pid no longer alive) is
  reclaimed rather than wedging forever.
- **pid-reuse safe**: liveness is tracked via a pidfile
  (`state/.spectrum-bridge.pid`) but a bare pid match is never trusted - the
  tracked pid's command line is checked (`ps -o command=`) to confirm it
  actually looks like the spectrum bridge before it is treated as "already
  running". A stale pidfile pointing at an unrelated live process (pid reuse)
  is ignored, and a fresh bridge is started instead - the unrelated process is
  never touched, and there is no broad `pkill`.
- **Stale/hung restart**: if the tracked process is alive but its liveness
  beacon (`state/.spectrum-bridge-beat`) has gone stale
  (`SPECTRUM_BRIDGE_STALE_SECS`, default 90s - the same threshold
  `fm-spectrum-status.sh` reports, via the shared `spectrum_beacon_state()`
  helper in `fm-spectrum-lib.sh`), it sends `SIGTERM`, waits briefly for a
  clean `app.stop()` shutdown, force-kills (`SIGKILL`) if it hasn't exited,
  then starts a fresh process. Only the specific tracked pid for this home is
  ever signaled.

**Where this is invoked** (both additive to the existing watcher backbone - no
edits to `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh`, or the
afk daemon):

1. **Session-start bootstrap** (`spectrum_bridge_supervise` in
   `bin/fm-bootstrap.sh`, part of the same locked mutating sweep as
   `spectrum_watch_setup`/`x_mode_setup`): gets the bridge running promptly at
   the start of every session that holds the fleet lock, without waiting for
   the first watcher check cycle.
2. **Every watcher check cycle** (`bin/fm-spectrum-poll.sh`, the body of the
   generated `state/spectrum-watch.check.sh` shim - see "Inbound wiring"
   below): re-checks on the same cadence as inbound polling
   (`FM_CHECK_INTERVAL=20` from `config/spectrum-mode.env`), so a bridge that
   dies mid-session (crash, reboot, OOM) is caught and restarted within one
   check interval instead of only at the next session start.

A routine `healthy` or `starting (pid ..., no beacon yet)` verdict is quiet in
both call sites (not captain-relevant); an actual restart (stale/hung) or a
fresh start-from-dead is surfaced as a bootstrap `SPECTRUM:` line or a watcher
`check:` wake, since those ARE worth knowing about.

You can still start or stop the bridge by hand for local iteration; nothing
about slice 2 removes that:

```sh
nohup bin/fm-spectrum-bridge >> state/spectrum-bridge.log 2>&1 &
```

Stop it with a normal signal (`kill <pid>`, or `Ctrl-C` if run in the
foreground) - it handles `SIGINT`/`SIGTERM` by calling `app.stop()` before
exiting. If it is under ensure-bridge supervision, the next check cycle (or
session start) will simply start a fresh one - `fm-spectrum-ensure-bridge.sh`
does not distinguish "you stopped it on purpose" from "it crashed"; that is
the intended always-on behavior. To take it down for longer, unset
`SPECTRUM_SELF_HANDLE` (or empty it) in `.env` and rerun bootstrap, which
removes `state/spectrum-watch.check.sh`/`config/spectrum-mode.env` so
supervision stops re-starting it (the already-running process, if any, is left
alone - stop it by hand with `kill <pid>`).

Check its health any time with:

```sh
bin/fm-spectrum-status.sh
```

which reports one of `disabled` (not configured - normal resting state),
`healthy` (beacon fresh), `stale` (beacon older than
`SPECTRUM_BRIDGE_STALE_SECS`, default 90s - the bridge may be hung or
crashed), or `dead` (configured but no beacon file at all - never started, or
torn down). `disabled` and `healthy` exit 0; `stale` and `dead` exit 1, so
`bin/fm-spectrum-ensure-bridge.sh` (which shares the same beacon-state logic
via `spectrum_beacon_state()`) and any other caller can script off it
directly.

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

### Auto-push escalations (`fm-spectrum-escalate.sh`, slice 2)

`bin/fm-spectrum-escalate.sh` is a thin, additive wrapper around
`fm-spectrum-notify.sh` that mirrors a captain-facing escalation
(AGENTS.md section 9: work ready for review, a blocker, a failure, a needed
decision or credential) out to the captain's phone - but only when doing so
would actually help:

```sh
bin/fm-spectrum-escalate.sh --text-file <path>
bin/fm-spectrum-escalate.sh -
bin/fm-spectrum-escalate.sh "<text>"
```

Both of these must hold, or the call is a **silent no-op** (exit 0, nothing
sent, nothing printed):

1. spectrum is configured (non-empty `SPECTRUM_SELF_HANDLE`).
2. `state/.afk` exists - away-mode is active (the `afk` skill / AGENTS.md
   section 8's "Away-mode stub" - the captain is not watching a live session
   right now).

When a session IS live, the normal chat-surfaced escalation already reaches
the captain, so this script deliberately stays quiet rather than duplicating
it. This is analogous to how the away-mode sub-supervisor daemon
(`bin/fm-supervise-daemon.sh`) surfaces batched escalations to the supervisor
pane while away - this script is the same idea aimed at a channel that
reaches the captain even when no pane is being watched at all, and it is
implemented entirely outside the daemon (a separate, standalone script
firstmate calls at its own escalation points) so the daemon itself needed no
changes.

Neither gate condition is an error, so it is safe for firstmate to call this
unconditionally at every section 9 escalation point: a captain who has never
configured the channel, or who is actively at the keyboard, sees zero
behavior change. It honors `SPECTRUM_DRY_RUN` exactly as `fm-spectrum-notify.sh`
does (same outbox path), so the whole gate -> compose -> would-send loop is
testable without a live account.

## Inbound wiring (slice 2)

The bridge already wrote every allowlisted inbound message to
`state/spectrum-inbox/<message.id>.json` in slice 1
(`{id, space_id, space_guid, sender, text, content_type, timestamp,
direction: "inbound"}`); slice 2 adds the piece that actually surfaces and
acts on it, mirroring X mode's poll -> inbox -> respond-skill shape exactly
(AGENTS.md section 14) rather than inventing a parallel one.

**The check shim.** `bin/fm-bootstrap.sh`'s `spectrum_watch_setup` (part of
the same locked mutating sweep as `x_mode_setup`) drops two idempotent,
gitignored artifacts when `SPECTRUM_SELF_HANDLE` is configured:

- `state/spectrum-watch.check.sh` - execs `bin/fm-spectrum-poll.sh` each cycle,
  exactly like `state/x-watch.check.sh` execs `bin/fm-x-poll.sh`.
- `config/spectrum-mode.env` - exports `FM_CHECK_INTERVAL=20`. Unlike X mode's
  30s cadence (bounded by relay rate limits and a real network round trip),
  spectrum's inbound path involves **no network call at all** - the bridge
  already wrote the file straight to local disk - so a tighter, purely-local
  20s check is cheap. If a home has both X mode and spectrum enabled, source
  both cadence files before arming the watcher
  (`[ -f config/x-mode.env ] && . config/x-mode.env; [ -f config/spectrum-mode.env ] && . config/spectrum-mode.env; bin/fm-watch-arm.sh`)
  - since each `export FM_CHECK_INTERVAL=...` simply overwrites the prior
    value, source spectrum's file LAST to get the tighter of the two
    cadences.

Both artifacts are removed on opt-out (emptying/removing `SPECTRUM_SELF_HANDLE`
and rerunning bootstrap), exactly like X mode's cleanup.

**The poll script.** `bin/fm-spectrum-poll.sh` is the check shim's body. It is
a hard no-op (silent, exit 0) when spectrum is not configured. When
configured, every cycle it:

1. Calls `bin/fm-spectrum-ensure-bridge.sh` (see "Starting / stopping the
   bridge" above) so the bridge stays supervised. A routine `healthy` verdict
   stays quiet; an actual restart or start-from-dead is surfaced.
2. Lists `state/spectrum-inbox/*.json` via `spectrum_inbox_list()`
   (`fm-spectrum-lib.sh`) - sorted, real records only (dotfiles and
   `*.json.tmp` remnants from an interrupted atomic write are skipped). If
   anything is pending, it prints one compact `spectrum-inbound <id>` line
   naming the OLDEST pending message.

No network calls, so this never needs `curl` and never holds a check cycle
open - the "polling" is really just a fast local directory listing plus the
bridge-supervision check.

**The `spectrum-respond` skill.** Loaded on a `spectrum-inbound <id>` `check:`
wake (`.agents/skills/spectrum-respond/`), it drains **every**
`state/spectrum-inbox/*.json` file (the watcher coalesces same-key wakes, so
one wake can stand in for several pending messages - the same contract
`fmx-respond` uses for `state/x-inbox/`), classifies each as a question, an
actionable instruction, or a pure acknowledgment, acts through firstmate's
normal lifecycle where appropriate, replies via `bin/fm-spectrum-notify.sh
--target <sender>`, and removes the inbox file on success. Unlike `fmx-respond`
this channel is **private** to the captain (every record is bridge-verified
against `SPECTRUM_CAPTAIN_HANDLE` before it ever reaches disk), so the public-
safety scrubbing `fmx-respond` performs is unnecessary here - replies may
speak plainly - but destructive/irreversible/security-sensitive requests still
require an explicit confirmation round-trip before firstmate acts. See the
skill file for the full playbook.

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

## Live verification

A real outbound send was verified end to end: `fm-spectrum-notify.sh --target
+12262246894 --text-file <file>` against a live `bin/fm-spectrum-bridge`
(Messages.app signed into `lily.lotuscloud@gmail.com`) produced a new
`message` row in `chat.db` with `is_from_me=1`,
`account=E:lily.lotuscloud@gmail.com`, to `+12262246894`, whose
`attributedBody` decoded to the exact sent text. The dry-run path could not
have caught the accessor bug above (it stubs the send before touching
`osascript`), which is why this live pass mattered.

**A macOS caveat worth knowing for unattended operation:** window/chat-touching
AppleEvents to Messages.app (`count windows`, `chat id "..." `, and the send
path itself) can hang for a fixed ~2 minutes and fail with `-1712` ("AppleEvent
timed out") when the console session is locked or otherwise not the active
foreground session - even though app-level AppleEvents (`get name`) return
instantly and the Automation→Messages TCC grant is genuinely in place. This is
distinct from the TCC permission-prompt hang `data/spectrum-local-v2/report.md`
documents (a one-time interactive Allow); it recurred on every attempt while
the console was inactive and cleared once the session was active, and
restarting Messages.app did not help. Keep the console session that runs the
bridge unlocked/active, or expect sends to fail with this timeout. Inbound
verification (a real captain message landing in `state/spectrum-inbox/`) was
not exercised in this pass - it requires the captain to send a live message
while the bridge is running, which is cheap to check the next time the bridge
is live but wasn't independently triggerable here.

## Manual smoke test (slice 2, real round trip)

Slice 2's automated suite
(`tests/fm-spectrum-mode-p2.test.sh`) is entirely deterministic - it exercises
`fm-spectrum-poll.sh`'s wake production, `fm-spectrum-ensure-bridge.sh`'s
idempotency/single-instance/stale-restart behavior, and `fm-spectrum-escalate.sh`'s
gating against a **fake** bridge binary (`SPECTRUM_BRIDGE_BIN` override), never
a real Messages account. That is deliberate: dry-run and a fake bridge can
verify every code path around the send EXCEPT the send accessor itself (a
`Spectrum()`/`imessage()` API change would still fail silently under a fake
binary). The send accessor stays covered by
`test_bridge_resolves_real_space_accessor` in `tests/fm-spectrum-mode.test.sh`
(slice 1), which runs against the REAL installed `spectrum-ts` package - that
regression test is what actually catches an upstream API change, not this
manual step.

This manual step is for proving the FULL loop works end to end against a real,
signed-in Messages.app session (needs the captain's Mac mini, the "Manual
prerequisite" and TCC grants from "Identities" above, and an active/unlocked
console session per the caveat above):

1. **Start real supervision.** With `SPECTRUM_SELF_HANDLE`/`SPECTRUM_CAPTAIN_HANDLE`
   set in `.env` and `SPECTRUM_DRY_RUN` unset, run `bin/fm-bootstrap.sh` (or
   just `bin/fm-spectrum-ensure-bridge.sh` directly) and confirm
   `bin/fm-spectrum-status.sh` reports `healthy`.
2. **Outbound.** `bin/fm-spectrum-notify.sh --text-file <file>` (or
   `bin/fm-spectrum-escalate.sh` with `state/.afk` present) and confirm the
   message arrives on the captain's phone - this repeats slice 1's live
   verification above, now against the supervised (not by-hand) bridge.
3. **Inbound.** From the captain's phone, reply to that conversation. Confirm
   a new `state/spectrum-inbox/<id>.json` appears within one check interval
   (~20s), and that the next `bin/fm-watch.sh` cycle reports a
   `check: .../spectrum-watch.check.sh: spectrum-inbound <id>` wake (or run
   `bin/fm-spectrum-poll.sh` directly and confirm it prints that line).
4. **Round trip.** With the `spectrum-respond` skill loaded on that wake,
   confirm it drains the inbox file, composes and sends a reply (visible on
   the captain's phone), and removes `state/spectrum-inbox/<id>.json`.
5. **Supervision.** Kill the bridge process (`kill <pid>` from
   `state/.spectrum-bridge.pid`) and confirm the next
   `bin/fm-spectrum-ensure-bridge.sh` call (bootstrap, or the next check
   cycle) starts a fresh one and `bin/fm-spectrum-status.sh` returns to
   `healthy`.

None of this is required for CI or for the automated suite to pass; it is the
step that proves the real macOS-only transport still works, the same role
slice 1's live verification played for the outbound send accessor.
