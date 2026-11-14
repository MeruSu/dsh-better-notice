# audio-endpoint — default audio *output* endpoint probe (task-46)

Windows-only CLI that answers one question: **which device is the sound coming out of right now**,
and — when the system will tell us — whether that device is headphones or speakers.

It prints **one JSON object on one stdout line**. Business failures are JSON too, with exit code 0.
A non-zero exit code means only that the script itself could not run.

```
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\audio-endpoint\audio-endpoint.ps1
```

Measured on this machine (2026-11-13, repeated runs):

```json
{"name":"耳机 (Baseus Bass BC2 Stereo)","direction":"render","kindGuess":"headphones","guess":false,"state":"measured","asOf":1794512782766,"elapsedMs":1146,"error":null}
```

## Output contract

| field | type | meaning |
| --- | --- | --- |
| `name` | string \| null | Friendly name of the default render endpoint (`PKEY_Device_FriendlyName`, pid 14). This is the reliable field. Falls back to `PKEY_Device_Description` (pid 2) only when the friendly name is empty. `null` when the endpoint could not be named. |
| `direction` | `"render"` | Always `render`. This tool never looks at input devices. |
| `kindGuess` | `"headphones"` \| `"speakers"` \| `"unknown"` | Device class. `headphones` = Headphones/Headset, `speakers` = Speakers/LineLevel. |
| `guess` | bool | `false` **only** when the type came from the system (`PKEY_AudioEndpoint_FormFactor`). `true` means "we inferred it from the name" — do not treat it as a fact. |
| `state` | `"measured"` \| `"degraded"` \| `"unknown"` | `measured` = system gave the type; `degraded` = name read, type inferred; `unknown` = could not read enough to say anything. |
| `asOf` | int (unix ms) | When the answer was produced. |
| `elapsedMs` | int | Wall time of the whole script, including PowerShell start-up. |
| `error` | string \| null | `null` on success. Otherwise a stable reason: `no-endpoint`, `access-denied`, `no-name`, `compile-failed:*`, `probe-failed:*`, each optionally suffixed `:hr=0x…`. |

Invariants that hold in every path:

* `guess === true` implies `state !== "measured"` — a heuristic result is never labelled measured.
* `state === "unknown"` always carries a non-null `error`.
* `kindGuess === "unknown"` with `state === "measured"` is legitimate: the system reported a form
  factor we refuse to translate (SPDIF, HDMI, RemoteNetworkDevice, …). We do not guess on top of a
  measured value.

## How it works

1. Core Audio COM: `MMDeviceEnumerator.GetDefaultAudioEndpoint(eRender, eMultimedia)`.
2. `IMMDevice.OpenPropertyStore(STGM_READ)` → `IPropertyStore`.
3. Walk **all** properties (`GetCount` → `GetAt` → `GetValue` for every key), keep the three we care
   about: `PKEY_AudioEndpoint_FormFactor` `{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E}:0`,
   `PKEY_Device_FriendlyName` `{A45C254E-DF1C-4EFD-8020-67D146A850E0}:14`,
   `PKEY_Device_Description` `…:2`.
4. Map form factor → `kindGuess`; if it is absent, fall back to a name heuristic and flag it.

The C# interop block is copied **verbatim** from the read-only probe
`cangku/tmp/261113_a1e_endpoint-props.ps1` (that probe dumped all 60 properties of this endpoint and
was reproduced many times). It is copied rather than retyped on purpose: the interop shape is the
only part that is proven, so it must not drift. Everything that turns raw properties into the
contract is plain PowerShell and can be reviewed without COM.

## Two interop landmines (measured here, not theory)

1. **`ref PropertyKey` across a method boundary kills the process.** A helper taking
   `(IPropertyStore store, ref PropertyKey key, …)` and calling `store.GetValue(ref key, out pv)`
   made the process die with `Fatal error. System.AccessViolationException`, exit code
   `-1073741819` (0xC0000005) — not catchable, no JSON, nothing. Passing `Guid` + `pid` **by value**
   and building the `PropertyKey` inside the callee is fine.
2. **Reading one key of interest first can come back `VT_EMPTY`.** Scanning for the FormFactor key
   and calling `GetValue` on just that key returned `hr=0, vt=0` in the same process in which a
   front-to-back walk of the store returned `hr=0, vt=19 (VT_UI4), value=3`. Walking the store and
   reading every value is what works; that is why step 3 above reads everything and then picks.

Also worth knowing: the property store is not stable in its ordering across processes, so keys are
matched by `fmtid`+`pid`, never by index.

## Honesty notes

* **The name is reliable, the type is not always available.** On this machine the endpoint reports
  `FormFactor = 3 (Headphones)` and the name says 耳机 — two independent sources agreeing. On other
  machines `FormFactor` may be missing or `UnknownFormFactor`; then `guess:true` + `state:degraded`
  is the honest answer, and a caller must not present it as a measurement.
* An earlier note in the task card said FormFactor reads `vt=0` (absent). That was **a wrong PKEY
  GUID** (`…E0C0CFFA43AE` instead of `…E0C0FFEE7F0E`); a wrong key and an absent property look
  identical (`VT_EMPTY`). With the right GUID the value is present here.
* WMI (`Get-PnpDevice`, `Win32_PnPEntity`) is **not** used. In the agent sandbox it returns
  `拒绝访问` (access denied); relying on it would make the tool fail depending on who runs it.

## Known limitations

1. **Windows only.** macOS/Linux are planned, not written. No cross-platform code was guessed in.
2. **Only one endpoint shape was exercised**: this machine has a single default render endpoint
   (a Bluetooth headset). The `speakers` mapping and the `no-name` path were reviewed but not
   observed on hardware — treat them as untested until someone runs it on a machine with speakers.
3. **No WMI fallback** (see above), so a machine whose Core Audio default endpoint is unavailable
   returns `no-endpoint` rather than trying to enumerate devices.
4. **`elapsedMs` is dominated by PowerShell start-up + `Add-Type` compile** (~1.0–1.3 s here); the
   property read itself is a few milliseconds. If this is ever wired into a hot path, precompile the
   assembly instead of calling `Add-Type` per run.
5. **stdout only.** If this is later spawned from a host plugin, do not capture it through a pipe:
   in this environment `stdio:'pipe'` fails with `EPERM`, so a result file (unique name, read, delete)
   is the working channel — same pattern as `dsh-presence-probe`.
6. **Not wired into `dsh-presence-probe` yet.** It is meant to become presence level 5; that
   integration is a separate decision (lead's call) and is deliberately not done here.
7. **No unit tests in v1.** The script has no pure functions to test offline; the only meaningful
   check is running it on real hardware. Adding a test would mean refactoring the mapping into a
   separate module — worth doing only if this becomes part of a larger component.

## Manual verification

```powershell
# 1. contract shape and values
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\audio-endpoint\audio-endpoint.ps1

# 2. is the JSON parseable and is it exactly one line?
$out = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\audio-endpoint\audio-endpoint.ps1
($out -split "`n").Count      # -> 1
$out | ConvertFrom-Json | Format-List

# 3. raw evidence: every property of the default render endpoint
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File cangku\tmp\261113_a1e_endpoint-props.ps1
```

## Files

```
tools/audio-endpoint/
  audio-endpoint.ps1   # the whole tool: C# interop heredoc + PowerShell contract logic
  README.md            # this file
```
