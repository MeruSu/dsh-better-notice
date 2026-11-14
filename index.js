/**
 * 热表 / Hot List — Host half.
 *
 * Three jobs:
 *
 *  1. Load the web client half (see client.js), which draws the session seats
 *     in the conversation tab row, the sidebar state markers and the settings
 *     page.
 *  2. Serve the bundled sound cues. The client package-asset route only knows
 *     image media types (`@deepseek-ai/dsh-client-modules` PACKAGE_ASSET_MEDIA_TYPES:
 *     .svg/.png/.webp/.jpg/.jpeg), so `.mp3` there answers 404 and a sound can
 *     never reach an `<audio>`/WebAudio decode. This route hands the same files
 *     out as `audio/mpeg` instead. User-uploaded cues are data URLs and do not
 *     come through here.
 *  3. Ring the whole screen once (`tools/attn-ring/Show-AttnRing.ps1`). The ring
 *     is a WPF process, so it cannot start from the browser: the client half
 *     only asks, this half spawns. Every failure stays a `console.debug` line —
 *     a machine without `pwsh`, or an install without the script, must still
 *     boot the plugin.
 */

import { spawn } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Prefix this plugin owns on the host Web server. */
const SOUND_ROUTE = "/hotlist-sound";

/** Prefix for the one-shot full-screen ring trigger. GET only, one header required. */
const RING_ROUTE = "/hotlist-ring";

/** Directory holding the bundled cues, resolved next to this file. */
const SOUND_DIR = join(dirname(fileURLToPath(import.meta.url)), "assets", "sounds");

/** The ring script ships inside the package, so an installed copy works on its own. */
const RING_SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "tools", "attn-ring", "Show-AttnRing.ps1");

/** The only three parameters the script implements; the rest of its tail is inert. */
const RING_SECONDS = { min: 1, max: 30, fallback: 4 };
const RING_SCOPES = ["Primary", "All"];
/** `Gif` draws one transparent clip instead of the amber ring; the three ring
 *  animations stay exactly as they were. */
const RING_ANIMS = ["Expand", "Breathe", "None", "Gif"];
/** Which clip a `Gif` ring plays. `error` and `pending` share the smack, `completed` waves. */
const RING_GIF_CATEGORIES = ["error", "pending", "completed"];

/** Prefix for the audio-endpoint probe. GET only, one header required. */
const AUDIO_ROUTE = "/hotlist-audio";

/** The probe script ships inside the package, like the ring script. */
const AUDIO_SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "tools", "audio-endpoint", "audio-endpoint.ps1");

/** How long one probe result stays usable before the script runs again. */
const AUDIO_TTL_MS = 60 * 1000;

/** Route that answers what the device-list file says. Served by the same prefix. */
const AUDIO_CONFIG_ROUTE = "/hotlist-audio/config";

/** The enumerator a user's own AI is told to run; ships in the package. */
const AUDIO_DEVICES_SCRIPT = join(
  dirname(fileURLToPath(import.meta.url)),
  "tools",
  "audio-endpoint",
  "audio-devices.ps1",
);

/**
 * Where the host would look for the list file. This is the only place the path
 * is built: the client never joins a path, it only echoes what this returns.
 * Same precedence as `@deepseek-ai/dsh-home-paths`: an explicit `DSH_HOME`
 * wins, a blank one counts as unset, and `~/.dsh` is the fallback.
 */
function dshHomeDir() {
  const configured = process.env.DSH_HOME;
  if (configured !== undefined && configured.trim().length > 0) return configured.trim();
  return join(homedir(), ".dsh");
}

function audioConfigFile() {
  return join(dshHomeDir(), "hotlist-audio.json");
}

/** Last parsed list file: cached by mtime, re-read on every mtime change. */
let audioConfigCache = { mtime: null, payload: null };

/** Direction aliases an AI may write; anything unknown counts as playback. */
const RENDER_ALIASES = ["render", "playback", "output", "输出", "播放"];
const CAPTURE_ALIASES = ["capture", "record", "input", "输入", "录制"];
const AUDIO_DEVICE_GROUPS = ["headphones", "speakers", "capture", "other"];

/** One ring per this window: a burst of state changes must not stack processes. */
const RING_COOLDOWN_MS = 2500;

/** Media type per served extension; anything else answers 404. */
const SOUND_MEDIA_TYPES = new Map([
  [".mp3", "audio/mpeg"],
  [".wav", "audio/wav"],
  [".ogg", "audio/ogg"],
  [".m4a", "audio/mp4"],
]);

/** Last time a ring was started, in ms; the cooldown reads it. */
let ringLastAt = -Infinity;

/** One slot for the audio probe: the payload, when it was taken, and whether a run is in flight. */
let audioCache = { at: -Infinity, payload: null, pending: false };

/** Bare file name of a cue URL, or undefined when the name is not a plain file of a served type. */
function servedName(pathname) {
  if (!pathname.startsWith(`${SOUND_ROUTE}/`)) return undefined;
  const name = decodeURIComponent(pathname.slice(SOUND_ROUTE.length + 1));
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) return undefined;
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return undefined;
  return SOUND_MEDIA_TYPES.has(name.slice(dot).toLowerCase()) ? name : undefined;
}

/** Answer one cue request; unknown or unreadable cues answer 404. */
async function serveSound(request) {
  const name = servedName(new URL(request.url).pathname);
  if (name === undefined) return new Response(null, { status: 404 });
  let body;
  try {
    body = await readFile(join(SOUND_DIR, name));
  } catch {
    return new Response(null, { status: 404 });
  }
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": SOUND_MEDIA_TYPES.get(name.slice(name.lastIndexOf(".")).toLowerCase()),
      "cache-control": "public, max-age=31536000, immutable",
      "x-content-type-options": "nosniff",
    },
  });
}

/**
 * Turn a query into script arguments, or a reason to refuse. Pure: the three
 * values are clamped to what the script accepts, never passed through raw, so a
 * stray `?seconds=99999` cannot hold the screen for five hours.
 */
function ringArgs(query) {
  const rawSeconds = Number(query.get("seconds"));
  const seconds = Number.isFinite(rawSeconds) ? Math.round(rawSeconds) : RING_SECONDS.fallback;
  const scope = query.get("scope");
  const requested = query.get("anim");
  const lower = typeof requested === "string" ? requested.toLowerCase() : "";
  const anim = RING_ANIMS.find((name) => name.toLowerCase() === lower) ?? RING_ANIMS[0];
  // `cat` only means something to a `Gif` ring. A stray `cat` on the amber ring is
  // ignored rather than quietly turning the request into something else.
  const wanted = query.get("cat");
  const gifCategory = anim !== "Gif"
    ? null
    : RING_GIF_CATEGORIES.includes(wanted) ? wanted : "pending";
  return {
    seconds: Math.min(RING_SECONDS.max, Math.max(RING_SECONDS.min, seconds)),
    scope: RING_SCOPES.includes(scope) ? scope : RING_SCOPES[0],
    anim,
    gifCategory,
  };
}

/** The exact argv the script is started with; also what a test asserts on. */
function ringCommand(args, scriptPath = RING_SCRIPT) {
  const argv = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-Seconds", String(args.seconds), "-Scope", args.scope, "-Anim", args.anim];
  if (args.anim === "Gif") argv.push("-GifCategory", args.gifCategory);
  return { script: scriptPath, argv };
}

/** The `pwsh` this host would start, or null when the machine has none on PATH. */
function resolvePwsh(env = process.env) {
  const fromEnv = typeof env.DSH_PWSH === "string" && env.DSH_PWSH !== "" ? env.DSH_PWSH : null;
  if (fromEnv !== null) return fromEnv;
  return "pwsh";
}

/**
 * Start the ring process and forget about it.
 *
 * Two option choices carry a whole afternoon of measuring:
 *
 *  - `stdio: "ignore"`: this machine's sandbox refuses named pipes, so
 *    `stdio: "pipe"` fails with EPERM before the process exists.
 *  - **no `detached`**: measured on 2026-11-14 — a `detached: true` child of
 *    this host starts, exits ~200 ms later with code 0 and never runs the
 *    script (same argv, `detached` removed, runs fine). The ring simply never
 *    appeared. Do not "improve" this by detaching.
 *
 * The `error` listener is mandatory: an unhandled `error` event on a
 * ChildProcess kills the whole host.
 */
function spawnRing(options) {
  const { args, scriptPath, log } = options;
  const start = typeof options.spawn === "function" ? options.spawn : spawn;
  if (existsSync(scriptPath) === false) {
    log("ring script missing", scriptPath);
    return false;
  }
  const built = ringCommand(args, scriptPath);
  let child;
  try {
    child = start(resolvePwsh(), built.argv, { stdio: "ignore", windowsHide: true });
  } catch (thrown) {
    log("ring spawn threw", thrown instanceof Error ? thrown.message : String(thrown));
    return false;
  }
  if (child === undefined || child === null) {
    log("ring spawn returned nothing");
    return false;
  }
  if (typeof child.on === "function") {
    child.on("error", (thrown) => log("ring spawn failed", thrown instanceof Error ? thrown.message : String(thrown)));
  }
  if (typeof child.unref === "function") child.unref();
  log("ring started", `${args.seconds}s`, args.scope, args.anim);
  return true;
}

/**
 * One ring request. Three gates, cheapest first: the marker header (a plain
 * `<img src>` from a foreign page cannot set it), the cooldown, then the spawn.
 */
function serveRing(request, deps = {}) {
  const log = typeof deps.log === "function" ? deps.log : (message, ...rest) => console.debug("[hotlist]", message, ...rest);
  try {
    if (request.headers.get("x-hotlist-ring") !== "1") {
      return Response.json({ ok: false, reason: "no-marker" }, { status: 403 });
    }
    const now = Date.now();
    if (now - ringLastAt < RING_COOLDOWN_MS) {
      log("ring cooling", now - ringLastAt);
      return Response.json({ ok: false, reason: "cooling" }, { status: 429 });
    }
    const args = ringArgs(new URL(request.url).searchParams);
    const started = spawnRing({
      args,
      scriptPath: deps.scriptPath ?? RING_SCRIPT,
      log,
      spawn: deps.spawn,
    });
    if (started === false) return Response.json({ ok: false, reason: "not-started" }, { status: 503 });
    ringLastAt = now;
    return Response.json({ ok: true, ...args });
  } catch (thrown) {
    log("ring request failed", thrown instanceof Error ? thrown.message : String(thrown));
    return Response.json({ ok: false, reason: "error" }, { status: 500 });
  }
}

/**
 * Run the audio-endpoint script once and cache the payload.
 *
 * The probe writes one JSON line on stdout, and this sandbox refuses named
 * pipes, so stdout goes to a temp file the host opens itself (`stdio` gets the
 * file descriptor, not a pipe). Business failures are still exit 0 and JSON on
 * that line — an unreadable file is cached as `unknown` rather than retried
 * every request.
 */
function spawnAudioProbe(deps = {}) {
  const log = typeof deps.log === "function" ? deps.log : (message, ...rest) => console.debug("[hotlist]", message, ...rest);
  if (audioCache.pending) return false;
  if (existsSync(AUDIO_SCRIPT) === false) {
    audioCache = { at: Date.now(), payload: unknownAudioPayload("script-missing"), pending: false };
    return false;
  }
  const tmp = join(tmpdir(), `hotlist-audio-${process.pid}-${Date.now()}.json`);
  let fd;
  try {
    fd = openSync(tmp, "w");
  } catch {
    return false;
  }
  audioCache = { ...audioCache, pending: true };
  let child;
  try {
    child = spawn(resolvePwsh(), ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", AUDIO_SCRIPT], {
      stdio: ["ignore", fd, "ignore"],
      windowsHide: true,
    });
  } catch (thrown) {
    try { closeSync(fd); } catch {}
    try { unlinkSync(tmp); } catch {}
    audioCache = { at: Date.now(), payload: unknownAudioPayload("spawn-threw"), pending: false };
    log("audio probe spawn threw", thrown instanceof Error ? thrown.message : String(thrown));
    return false;
  }
  const settle = (payload) => {
    try { closeSync(fd); } catch {}
    try { unlinkSync(tmp); } catch {}
    audioCache = { at: Date.now(), payload, pending: false };
  };
  child.on("error", (thrown) => {
    settle(unknownAudioPayload("spawn-failed"));
    log("audio probe spawn failed", thrown instanceof Error ? thrown.message : String(thrown));
  });
  child.on("close", (code) => {
    let payload = null;
    try {
      const line = readFileSync(tmp, "utf8").trim().split(/\r?\n/).filter(Boolean).pop();
      if (typeof line === "string") payload = JSON.parse(line);
    } catch {
      payload = null;
    }
    settle(payload === null ? unknownAudioPayload(`exit-${code}`) : payload);
  });
  if (typeof child.unref === "function") child.unref();
  log("audio probe started");
  return true;
}

/** The honest "no answer" payload: `state: unknown` is what the client gate refuses. */
function unknownAudioPayload(reason) {
  return {
    name: null,
    direction: "render",
    kindGuess: "unknown",
    guess: false,
    state: "unknown",
    asOf: Date.now(),
    elapsedMs: 0,
    error: reason,
  };
}

/** Map whatever was written into one of the two directions the gate understands. */
function normalizeDirection(value) {
  if (typeof value !== "string") return "render";
  const lowered = value.trim().toLowerCase();
  if (CAPTURE_ALIASES.includes(lowered)) return "capture";
  if (RENDER_ALIASES.includes(lowered)) return "render";
  return "render";
}

/** A group outside the four known ones is `other`: never guessed into headphones. */
function normalizeGroup(value) {
  if (typeof value !== "string") return "other";
  const lowered = value.trim().toLowerCase();
  return AUDIO_DEVICE_GROUPS.includes(lowered) ? lowered : "other";
}

/** One row of the file, or `null` when the row cannot name a device. */
function normalizeAudioDevice(entry) {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return null;
  if (typeof entry.name !== "string" || entry.name.trim() === "") return null;
  return {
    name: entry.name,
    direction: normalizeDirection(entry.direction),
    group: normalizeGroup(entry.group),
    kindGuess: typeof entry.kindGuess === "string" ? entry.kindGuess : "unknown",
    guess: entry.guess === true,
  };
}

/**
 * Read the list file. Eight tolerance rules, none of which may throw:
 * missing file, UTF-8 BOM, unparsable JSON, wrong `version`, non-array
 * `devices`, a single object instead of an array, an unusable row, and
 * unknown direction/group spellings. Everything except a real runtime error
 * answers `ok: true`, so the client never has to treat "bad file" as "host down".
 */
function readAudioConfig() {
  const path = audioConfigFile();
  let exists = false;
  let mtime = null;
  try {
    const info = statSync(path);
    exists = true;
    mtime = Number(info.mtimeMs);
  } catch {
    exists = false;
  }
  if (exists === false) {
    audioConfigCache = { mtime: null, payload: null };
    return { exists: false, valid: false, reason: "missing" };
  }
  if (audioConfigCache.mtime === mtime && audioConfigCache.payload !== null) {
    return audioConfigCache.payload;
  }
  let parsed = null;
  let error = null;
  try {
    const raw = readFileSync(path, "utf8").replace(/^\uFEFF/, "");
    parsed = JSON.parse(raw);
  } catch (thrown) {
    error = thrown instanceof Error ? String(thrown.message).split(/\r?\n/)[0].slice(0, 200) : "unreadable";
  }
  const base = { exists: true, path, directory: dirname(path) };
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    const payload = { ...base, valid: false, reason: "invalid", error: error ?? "not an object" };
    audioConfigCache = { mtime, payload };
    return payload;
  }
  if (parsed.version !== 1) {
    const payload = { ...base, valid: false, reason: "invalid", error: error ?? `unsupported version: ${String(parsed.version)}` };
    audioConfigCache = { mtime, payload };
    return payload;
  }
  let rows = parsed.devices;
  if (rows !== null && typeof rows === "object" && Array.isArray(rows) === false) rows = [rows];
  if (Array.isArray(rows) === false) {
    const payload = { ...base, valid: false, reason: "invalid", error: "devices is not an array" };
    audioConfigCache = { mtime, payload };
    return payload;
  }
  const devices = rows.map(normalizeAudioDevice).filter((device) => device !== null);
  const headphones = devices.filter((device) => device.direction === "render" && device.group === "headphones");
  const payload = {
    ...base,
    valid: true,
    updatedAt: Number.isFinite(Number(parsed.updatedAt)) ? Number(parsed.updatedAt) : null,
    devices,
    deviceCount: devices.length,
    headphoneCount: headphones.length,
    guessCount: devices.filter((device) => device.guess === true).length,
  };
  audioConfigCache = { mtime, payload };
  return payload;
}

/** One answer about the list file. A read failure is still `ok: true`, with `hostDown`. */
function serveAudioConfig(request) {
  try {
    if (request.headers.get("x-hotlist-audio") !== "1") {
      return Response.json({ ok: false, reason: "no-marker" }, { status: 403 });
    }
    const read = readAudioConfig();
    const script = existsSync(AUDIO_DEVICES_SCRIPT) ? AUDIO_DEVICES_SCRIPT : null;
    return Response.json({
      ok: true,
      exists: read.exists === true,
      valid: read.valid === true,
      path: audioConfigFile(),
      directory: dirname(audioConfigFile()),
      script,
      platform: process.platform,
      updatedAt: read.updatedAt ?? null,
      deviceCount: read.deviceCount ?? 0,
      headphoneCount: read.headphoneCount ?? 0,
      guessCount: read.guessCount ?? 0,
      devices: Array.isArray(read.devices) ? read.devices : [],
      ...(read.reason === undefined ? {} : { reason: read.reason }),
      ...(read.error === undefined ? {} : { error: read.error }),
    });
  } catch (thrown) {
    const message = thrown instanceof Error ? thrown.message : String(thrown);
    console.debug("[hotlist] audio config request failed", message);
    return Response.json({ ok: false, reason: "error", error: message }, { status: 500 });
  }
}

/**
 * One audio prefix, two answers: `/hotlist-audio` is the endpoint probe and
 * `/hotlist-audio/config` is the device list. Dispatch by pathname instead of
 * registering a second prefix, so the router's prefix ordering cannot decide
 * which handler a request reaches.
 */
function serveAudioRequest(request) {
  let pathname = "";
  try {
    pathname = new URL(request.url).pathname.replace(/\/+$/, "");
  } catch {
    pathname = "";
  }
  if (pathname === `${AUDIO_ROUTE}/config`) return serveAudioConfig(request);
  return serveAudio(request);
}

/** One audio probe request. A fresh cache answers instantly; otherwise a background run starts. */
function serveAudio(request) {
  try {
    if (request.headers.get("x-hotlist-audio") !== "1") {
      return Response.json({ ok: false, reason: "no-marker" }, { status: 403 });
    }
    const now = Date.now();
    if (audioCache.payload !== null && now - audioCache.at <= AUDIO_TTL_MS) {
      return Response.json({ ok: true, cached: true, ...audioCache.payload });
    }
    spawnAudioProbe();
    if (audioCache.payload !== null) return Response.json({ ok: true, cached: false, ...audioCache.payload });
    return Response.json({ ok: true, cached: false, ...unknownAudioPayload("measuring") });
  } catch (thrown) {
    const log = (message, ...rest) => console.debug("[hotlist]", message, ...rest);
    log("audio request failed", thrown instanceof Error ? thrown.message : String(thrown));
    return Response.json({ ok: false, reason: "error" }, { status: 500 });
  }
}

/**
 * Mount the two routes once a Web server exists; without one (a headless
 * profile) the plugin still loads, cues stay silent and the ring never fires.
 */
function apply(ctx) {
  ctx.inject(["webServer"], (webCtx) => {
    webCtx.effect(
      () =>
        webCtx.webServer.register({
          kind: "prefix",
          path: SOUND_ROUTE,
          resource: (request) => serveSound(request),
        }),
      "hotlist: bundled sound cues",
    );
    webCtx.effect(
      () =>
        webCtx.webServer.register({
          kind: "prefix",
          path: RING_ROUTE,
          resource: (request) => serveRing(request),
        }),
      "hotlist: full-screen ring",
    );
    webCtx.effect(
      () =>
        webCtx.webServer.register({
          kind: "prefix",
          path: AUDIO_ROUTE,
          resource: (request) => serveAudioRequest(request),
        }),
      "hotlist: audio endpoint probe",
    );
  });
}

export { apply, AUDIO_CONFIG_ROUTE, AUDIO_DEVICES_SCRIPT, AUDIO_ROUTE, AUDIO_SCRIPT, dshHomeDir, normalizeAudioDevice, normalizeDirection, normalizeGroup, readAudioConfig, serveAudioConfig, serveAudioRequest, RING_ANIMS, RING_GIF_CATEGORIES, RING_ROUTE, RING_SCRIPT, RING_SCOPES, SOUND_ROUTE, ringArgs, ringCommand, serveAudio, serveRing, spawnAudioProbe, spawnRing };
