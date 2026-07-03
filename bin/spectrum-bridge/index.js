#!/usr/bin/env node
'use strict';

// The fm-spectrum iMessage bridge. Launched by ../fm-spectrum-bridge (a bash
// script that owns all .env/config resolution and gating); this file is a pure
// logic executor that trusts its environment and never parses .env itself.
//
// Inbound: tails app.messages (spectrum-ts local iMessage mode - reads
// ~/Library/Messages/chat.db directly, no network, no Photon credentials) and
// writes each allowlisted inbound message atomically to
// state/spectrum-inbox/<message.id>.json. FM_SPECTRUM_CAPTAIN may list more
// than one reachable captain handle (comma-separated, e.g. an email and a
// phone number both signed into iMessage); a message from any of them is
// allowlisted. Nothing consumes that inbox yet in this slice - wiring it into
// firstmate's wake queue is a follow-up.
//
// Outbound: polls state/spectrum-outbox/ for JSON drop files written by
// bin/fm-spectrum-notify.sh ({id, target, text, ts, dry_run}) and sends each via
// osascript-driven Messages.app, unless dry-run (either the file's own
// dry_run:true, or this process's own FM_SPECTRUM_DRY env) - in which case the
// send is stubbed (logged, never executed) and the file is still consumed.
//
// Liveness: touches state/.spectrum-bridge-beat on a fixed interval so
// bin/fm-spectrum-status.sh can tell a live bridge from a hung/crashed one.
// This script never touches bin/fm-watch.sh, fm-watch-arm.sh, fm-wake-lib.sh,
// or the afk daemon - additive only, per the design.

const fs = require('fs');
const path = require('path');

function isTruthy(v) {
  if (!v) return false;
  switch (String(v).trim().toLowerCase()) {
    case '':
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return true;
  }
}

// Parse a comma-separated handle list (e.g. SPECTRUM_CAPTAIN_HANDLE, which may
// name more than one reachable handle for the same captain - an email and a
// phone number both signed into iMessage). Trims whitespace around each
// entry and drops empties, so "a@x.com, +1..., " -> ["a@x.com", "+1..."].
function parseHandleList(raw) {
  return String(raw || '')
    .split(',')
    .map((h) => h.trim())
    .filter((h) => h.length > 0);
}

// Inbound sender allowlist: true iff `sender` matches (case-insensitively) any
// handle in `captainHandles`. A private two-person channel, not a public
// inbox, so anything not on the list is dropped, never stashed.
function isFromCaptain(message, captainHandles) {
  const sender = message?.sender?.handle || message?.sender?.id || message?.sender;
  if (typeof sender !== 'string') return false;
  const lowerSender = sender.toLowerCase();
  return captainHandles.some((h) => h.toLowerCase() === lowerSender);
}

const STATE = process.env.FM_SPECTRUM_STATE;
const SELF_HANDLE = process.env.FM_SPECTRUM_SELF;
const CAPTAIN_HANDLES = parseHandleList(process.env.FM_SPECTRUM_CAPTAIN);
const DRY_RUN = isTruthy(process.env.FM_SPECTRUM_DRY);

const INBOX_DIR = STATE ? path.join(STATE, 'spectrum-inbox') : null;
const OUTBOX_DIR = STATE ? path.join(STATE, 'spectrum-outbox') : null;
const BEACON_PATH = STATE ? path.join(STATE, '.spectrum-bridge-beat') : null;

const BEACON_INTERVAL_MS = 15_000;
const OUTBOX_POLL_INTERVAL_MS = 2_000;

function touchBeacon() {
  try {
    fs.writeFileSync(BEACON_PATH, `${Date.now()}\n`);
  } catch (err) {
    console.error(`fm-spectrum-bridge: failed to touch beacon: ${err.message}`);
  }
}

function ensureDirs() {
  for (const dir of [STATE, INBOX_DIR, OUTBOX_DIR]) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

// Atomically write JSON so a concurrent reader (a future poll shim) never sees
// a half-written file - write to a sibling temp file, then rename.
function writeJsonAtomic(finalPath, obj) {
  const tmpPath = `${finalPath}.tmp.${process.pid}`;
  fs.writeFileSync(tmpPath, JSON.stringify(obj, null, 2) + '\n');
  fs.renameSync(tmpPath, finalPath);
}

// spectrum-ts's Space/User accessor naming for a proactive (not
// reply-triggered) send is not fully pinned down by the design report - it
// cites `im.space.get(id).send(...)` where `im` is a provider-specific handle,
// but the exact property Spectrum() exposes that handle under was not
// independently re-verified for the bridge implementation. Try the documented
// shapes in order and fail loudly (never guess-and-send) if none match, so a
// live account never gets a malformed call.
async function resolveSpaceGetter(app) {
  if (app.im && typeof app.im.space?.get === 'function') return app.im.space.get.bind(app.im.space);
  if (typeof app.space?.get === 'function') return app.space.get.bind(app.space);
  throw new Error(
    'could not find a space.get(id) accessor on the Spectrum app instance ' +
      '(tried app.im.space.get and app.space.get) - spectrum-ts API surface ' +
      'may have changed since data/spectrum-local-v2/report.md was written'
  );
}

async function sendOutbound(app, target, text) {
  const getSpace = await resolveSpaceGetter(app);
  const space = await getSpace(target);
  await space.send(text);
}

async function processOutboxFile(app, filePath) {
  let record;
  try {
    record = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (err) {
    console.error(`fm-spectrum-bridge: skipping unreadable outbox file ${filePath}: ${err.message}`);
    fs.unlinkSync(filePath);
    return;
  }

  const { target, text, dry_run: fileDryRun } = record;
  const dry = DRY_RUN || Boolean(fileDryRun);

  if (dry) {
    console.error(`fm-spectrum-bridge: DRY RUN - would send to ${target}: ${String(text).slice(0, 200)}`);
  } else {
    try {
      await sendOutbound(app, target, text);
      console.error(`fm-spectrum-bridge: sent to ${target}`);
    } catch (err) {
      console.error(`fm-spectrum-bridge: send to ${target} failed: ${err.message}`);
      // Leave the file in place so a restart can retry, rather than silently
      // dropping a captain-bound escalation.
      return;
    }
  }

  fs.unlinkSync(filePath);
}

function pollOutbox(app) {
  let files;
  try {
    files = fs
      .readdirSync(OUTBOX_DIR)
      .filter((f) => f.endsWith('.json') && !f.startsWith('.'))
      .sort();
  } catch (err) {
    console.error(`fm-spectrum-bridge: cannot read outbox dir: ${err.message}`);
    return;
  }
  for (const file of files) {
    processOutboxFile(app, path.join(OUTBOX_DIR, file)).catch((err) => {
      console.error(`fm-spectrum-bridge: error processing outbox file ${file}: ${err.message}`);
    });
  }
}

async function handleInbound(space, message) {
  if (!isFromCaptain(message, CAPTAIN_HANDLES)) {
    console.error(`fm-spectrum-bridge: dropping inbound message from non-captain sender (allowlist: ${CAPTAIN_HANDLES.join(', ')})`);
    return;
  }
  if (!message.id) {
    console.error('fm-spectrum-bridge: dropping inbound message with no id');
    return;
  }

  const record = {
    id: message.id,
    space_id: space?.id ?? null,
    space_guid: space?.guid ?? null,
    sender: message.sender?.handle ?? message.sender ?? null,
    text: message.content?.text ?? null,
    content_type: message.content?.type ?? null,
    timestamp: message.timestamp ? new Date(message.timestamp).toISOString() : null,
    direction: 'inbound',
  };

  const finalPath = path.join(INBOX_DIR, `${message.id}.json`);
  try {
    writeJsonAtomic(finalPath, record);
  } catch (err) {
    console.error(`fm-spectrum-bridge: failed to write inbox record for ${message.id}: ${err.message}`);
  }
}

async function main() {
  ensureDirs();

  let Spectrum, imessage;
  try {
    ({ Spectrum } = require('spectrum-ts'));
    ({ imessage } = require('@spectrum-ts/imessage'));
  } catch (err) {
    // This is the expected, graceful-failure path in any environment where
    // `npm install` has not been run inside bin/spectrum-bridge/ yet
    // (including CI/dev sandboxes, which cannot exercise the real macOS-only
    // local iMessage transport anyway). Fail fast and clearly rather than
    // limping along without the ability to actually bridge messages.
    console.error(
      'fm-spectrum-bridge: spectrum-ts dependencies are not installed. ' +
        'Run: (cd bin/spectrum-bridge && npm install)'
    );
    console.error(`fm-spectrum-bridge: underlying error: ${err.message}`);
    process.exit(1);
  }

  // Local mode: zero Photon credentials, reads chat.db directly and sends via
  // osascript-driven Messages.app. See data/spectrum-local-v2/report.md.
  let app;
  try {
    app = await Spectrum({ providers: [imessage.config({ local: true })] });
  } catch (err) {
    console.error(`fm-spectrum-bridge: failed to start Spectrum local iMessage client: ${err.message}`);
    console.error(
      'fm-spectrum-bridge: this usually means Messages.app is not running/signed in, ' +
        'or the macOS Full Disk Access / Automation->Messages permissions are not granted. ' +
        'See docs/spectrum-backend.md.'
    );
    process.exit(1);
  }

  touchBeacon();
  const beaconTimer = setInterval(touchBeacon, BEACON_INTERVAL_MS);
  const outboxTimer = setInterval(() => pollOutbox(app), OUTBOX_POLL_INTERVAL_MS);

  let stopping = false;
  const shutdown = async (signal) => {
    if (stopping) return;
    stopping = true;
    console.error(`fm-spectrum-bridge: received ${signal}, shutting down`);
    clearInterval(beaconTimer);
    clearInterval(outboxTimer);
    try {
      await app.stop();
    } catch (err) {
      console.error(`fm-spectrum-bridge: error during shutdown: ${err.message}`);
    }
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  console.error(
    `fm-spectrum-bridge: running as ${SELF_HANDLE} (captain allowlist: ${CAPTAIN_HANDLES.join(', ')}, dry_run=${DRY_RUN})`
  );

  for await (const [space, message] of app.messages) {
    await handleInbound(space, message);
  }
}

// Only validate environment and actually run when this file is the process
// entry point (`node index.js`), not when it's require()'d - e.g. by a test
// that wants the pure helpers above (parseHandleList, isFromCaptain,
// isTruthy) without needing FM_SPECTRUM_* set or a live Spectrum connection.
if (require.main === module) {
  // Defensive: the bash launcher (fm-spectrum-bridge) already gates on these
  // being present, but this file can be invoked directly (e.g. `node
  // index.js` during development), so re-validate here rather than trust the
  // caller.
  if (!STATE || !SELF_HANDLE || CAPTAIN_HANDLES.length === 0) {
    console.error(
      'fm-spectrum-bridge: missing required environment ' +
        '(FM_SPECTRUM_STATE, FM_SPECTRUM_SELF, FM_SPECTRUM_CAPTAIN) - ' +
        'run this via bin/fm-spectrum-bridge, not directly.'
    );
    process.exit(1);
  }

  main().catch((err) => {
    console.error(`fm-spectrum-bridge: fatal error: ${err.stack || err.message}`);
    process.exit(1);
  });
} else {
  module.exports = { isTruthy, parseHandleList, isFromCaptain };
}
