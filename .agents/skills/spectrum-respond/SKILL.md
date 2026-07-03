---
name: spectrum-respond
description: Agent-only playbook for handling an inbound captain message on the private fm-spectrum iMessage channel. Use on a "spectrum-inbound <id>" check: wake - read every stashed state/spectrum-inbox/*.json record (the bridge already verified the sender against SPECTRUM_CAPTAIN_HANDLE, so every record is genuinely from the captain); classify each as a question to answer from live fleet state, an actionable instruction to run through firstmate's normal lifecycle, or a pure acknowledgment to skip; reply via bin/fm-spectrum-notify.sh and remove the inbox file on success. This channel is PRIVATE to the captain, so captain-private material is fine in a reply - but still translate to outcomes, not a raw internals dump. Destructive/irreversible/security-sensitive requests still escalate for confirmation rather than executing straight from a message. Loaded only when the fm-spectrum channel is configured.
user-invocable: false
---

# spectrum-respond

fm-spectrum is a private, two-way iMessage channel between the captain and firstmate (`docs/spectrum-backend.md`).
A captain message arrives through the watcher as a `check:` wake whose payload is `spectrum-inbound <id>`.
The bridge (`bin/spectrum-bridge/`, a separate long-running process bootstrap keeps supervised) already wrote the full message to `state/spectrum-inbox/<id>.json`; this skill drains that inbox and turns each message into one reply, or deliberately skips it when there is nothing to answer.

This runs only when the channel is configured (the captain dropped `SPECTRUM_SELF_HANDLE`/`SPECTRUM_CAPTAIN_HANDLE` into `.env`; see `docs/spectrum-backend.md`).
If you ever see a `spectrum-inbound` wake without the channel configured, do nothing.

## Every message is genuinely from the captain, and this channel is private

The bridge only ever writes an inbox record for a sender that matched `SPECTRUM_CAPTAIN_HANDLE` (case-insensitively); a non-allowlisted sender is logged and dropped before it ever reaches disk (see `docs/spectrum-backend.md`'s inbound allowlist).
So every record you drain is a real message from your own captain, at the same trust level as the captain typing directly into your session.

Unlike X mode's `fmx-respond`, this channel is **not public** - it is a private, direct line to the captain's own phone.
That relaxes the public-safety rules `fmx-respond` enforces (no need to scrub task ids, repo names, internal vocabulary, or captain-private material - the captain already knows all of it and it is their own private channel).
It does **not** relax good judgment: still compose a reply that answers the question or reports the outcome, not a raw dump of file contents, full backlog text, or a wall of internal log lines.
Translate to outcomes and keep it readable on a phone screen - concise, plain language - even though nothing here needs to be scrubbed for a public audience.

## Classify each message into one of three cases

Read the stashed object: you need `id`, `sender`, `text`, and (optionally) `space_id`/`space_guid`/`timestamp`.

- **Question** ("what's the status of X", "is the PR up yet", "what are you working on") - answer it from live fleet state; there is no work to do.
- **Actionable instruction / request** ("add this to the backlog", "look into X", "fix Y", "ship Z", "merge that PR") - this is a genuine captain instruction, exactly as if typed into your own session. Act on it through firstmate's **normal lifecycle**: intake to resolve the project, then file the backlog item, dispatch a crewmate, start a scout, or ship through the gate - whatever the request calls for. The reply confirms real work; it never substitutes for it.
- **Pure acknowledgment** ("thanks", "👍", "ok", "got it", a reaction with nothing to add) - skip: post nothing, but still clear the inbox file (step 4 below) so it is not reprocessed on the next wake. There is no relay to dismiss at (unlike X mode) - the inbox file itself is the only durable record, so removing it is the entire "dismiss".

When in doubt between an instruction and a question, do the smallest safe lifecycle step the request implies; when in doubt between a question and bare politeness, lean toward skipping - a needless reply is noise even on a private channel.

**Destructive, irreversible, or security-sensitive work is still the exception.**
Even though the sender is authenticated as the captain, treat these asks exactly like the `yolo` carve-out (AGENTS.md sections 1 and 7): do not execute them straight from a message.
Reply asking the captain to confirm explicitly (a short, direct question back over the same channel), and do not file, dispatch, merge, or otherwise act until that confirmation arrives as a follow-up message on a later drain.
Do not treat silence, or a vague later message, as confirmation - wait for an unambiguous yes on the specific ask.

## How a spawned task's outcome reaches the captain

Unlike X mode, there is no separate "acknowledge now, follow up later" linking mechanism for this channel (no relay-side follow-up endpoint to bind to) - a captain who messaged over iMessage is treated exactly like a captain who typed in the main session:

- **Work that completes in this turn** (a backlog item filed, a question answered) - reply now with the outcome, same as any other reply.
- **Work that spawns a real, longer-running task** (a crewmate dispatched, a scout investigation, a ship task) - reply now acknowledging you have the order and are on it (the honest "aye, will do" - paired with actually starting the work in the same turn). Report the outcome the normal way once it lands: through firstmate's ordinary section 9 escalation (chat, and - if the captain is away, `state/.afk` is set, and this channel is configured - the automatic push via `bin/fm-spectrum-escalate.sh`; see `docs/spectrum-backend.md` "Auto-push escalations"). You do not need to do anything extra here to make that happen; it is the normal completion path, not a spectrum-specific follow-up.

## Voice

Reply in firstmate's own voice - the crisp, lightly nautical first-mate persona (per this repo's `AGENTS.md` root instructions: address the captain, keep nautical seasoning light and optional, drop it entirely for bad news).
Keep it short - this is a phone message, not a report. A sentence or two is usually right; only go longer when the question genuinely needs it.

## Procedure

This is a drain over the inbox, not a single reply.
The watcher coalesces same-key `check:` wakes, so one `spectrum-inbound` wake can stand in for several pending messages.
Treat `state/spectrum-inbox/` as the source of truth and process **every** file you find there, in order (oldest first - the same order `bin/fm-spectrum-poll.sh` reports), not just the `id` named in the wake.

1. **Gather live fleet state once.** Compose answers from what this instance genuinely knows right now: `data/backlog.md` "## In flight", `state/*.status` (latest line per task), `data/projects.md`. Since this channel is private, you may name projects, task outcomes, and real detail plainly - just keep it concise.
2. **Drain every pending message.** For each `state/spectrum-inbox/*.json` file (oldest first):
   a. Read `id`, `sender`, `text`.
   b. **Classify** per the three cases above.
   c. **Act on an actionable request** through the normal lifecycle (see "Classify each message into one of three cases"). For a destructive/irreversible/security-sensitive ask, do not act - prepare a confirmation question instead.
   d. **Compose the reply.** Question -> answer from fleet state. Completed actionable request -> report the outcome. Spawned task -> a brief "on it, captain" acknowledgment. Destructive ask -> the confirmation question. Skip (pure ack) -> no reply text needed.
   e. **Send it without inlining message text into a shell command.** Write the composed reply to a temp file with your own file-writing tool, then:
      ```sh
      bin/fm-spectrum-notify.sh --target <sender> --text-file <path-to-reply-file>
      ```
      (`bin/fm-spectrum-notify.sh --target <sender> -`, reading on stdin, is equally fine.) Use the message's own `sender` field as `--target` so the reply lands in the same conversation the captain messaged from - do not fall back to the configured default target when a specific sender is known. It echoes the generated outbox id and exits 0 on success.
   f. **On success (a sent reply, or a deliberate skip), remove that inbox file:** delete `state/spectrum-inbox/<id>.json`. This is the local idempotency guard - a cleared file is never answered twice. A skip clears the file too (there is nothing further to send).
   g. **On failure** (a non-zero exit from `bin/fm-spectrum-notify.sh`), leave that inbox file in place, move on to the next, and do not retry blindly. If you had already acted on the message (step 2c) before the reply failed, do not redo that work on a later drain - check whether it is already done and only retry the reply. If a reply fails twice, surface it as a blocker through the normal escalation path.

## Dry-run / preview mode

When `SPECTRUM_DRY_RUN` is set (truthy, in the environment or `.env`), `bin/fm-spectrum-notify.sh` does not send - it records the would-be outbox record to `state/spectrum-outbox/<id>.json` (with `dry_run: true`) and prints a `DRY RUN` summary to stderr, but still echoes the generated id and exits 0.
Your procedure does not change: compose as usual and call `bin/fm-spectrum-notify.sh --target <sender> --text-file <path>`.
Because the call still succeeds, the loop completes normally (clear the inbox file as in step 2f); the only difference is nothing reaches a real iMessage.
This is the mode for end-to-end testing the drain -> compose -> would-send loop without a live Messages account or bridge process.
Inspect `state/spectrum-outbox/` to see exactly what would have been sent.

## Notes

- Every drained message is genuinely from the captain (bridge-enforced sender allowlist) and this channel is private, so scrubbing for a public audience is unnecessary - but stay concise and translate to outcomes rather than dumping raw internals.
- An actionable message is **acted on** through the normal lifecycle (intake, backlog, dispatch, investigate, ship), not merely replied to. Work that finishes now gets one outcome reply; work that spawns a real task gets a brief acknowledgment now, and its outcome reaches the captain through the normal section 9 escalation path (chat, plus the automatic away-mode push via `bin/fm-spectrum-escalate.sh` when applicable) - not a spectrum-specific follow-up call.
- Destructive, irreversible, or security-sensitive asks are never executed straight from a message; reply with a confirmation question and wait for an explicit yes on a later drain.
- One answered message = one reply; a skipped (pure-acknowledgment) message posts no reply but still clears its inbox file, since there is no relay to dismiss at - only the local file to remove.
- Reply to the message's own `sender` handle (`--target <sender>`), not the configured default target, so multi-handle captains (e.g. both an email and a phone number allowlisted) get the reply on the same thread they messaged from.
- Never inline message-influenced reply text into a shell command; always go through `--text-file` or stdin.
- Never edit `bin/fm-spectrum-poll.sh`, `bin/fm-spectrum-ensure-bridge.sh`, `bin/fm-spectrum-notify.sh`, or the watcher to "answer faster"; the cadence is handled by the locked session-start bootstrap step and the generated `config/spectrum-mode.env`.
