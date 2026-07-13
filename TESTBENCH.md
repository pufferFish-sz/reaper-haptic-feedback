# REAPER Haptics Test Bench

Downstream half of the REAPER haptics authoring pipeline: play and validate
REAPER-exported `.ahap` files (and `HapticEvent[]` JSON) on real devices with
the fastest possible iteration loop. See `CLAUDE.md` for the pipeline spec.

## What was added to this repo

| Piece                 | Where                                                    | What it does                                                                                                                                                                                                             |
| --------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Validator + converter | [`src/utils/ahap.ts`](src/utils/ahap.ts)                 | `validateAhap()`, `validateHapticEvents()`, `ahapToHapticEvents()` (AHAP seconds → HapticEvent milliseconds). Exported from the library root, unit-tested in [`src/__tests__/ahap.test.ts`](src/__tests__/ahap.test.ts). |
| CLI validator         | [`scripts/validate-ahap.js`](scripts/validate-ahap.js)   | Check files on Windows before they ever reach a device.                                                                                                                                                                  |
| Test-bench UI         | [`example/src/TestBench.tsx`](example/src/TestBench.tsx) | "REAPER Bench" tab in the example app: URL hot-reload with watch mode, paste-in JSON, validation report, event timeline.                                                                                                 |

## 0. Authoring in REAPER (the upstream half)

**Designers only need one thing:
[`scripts/reaper/ReaperHaptics_Panel.lua`](scripts/reaper/ReaperHaptics_Panel.lua)**
— a dockable panel (native gfx, no ReaImGui required) with the whole
workflow as numbered buttons:

1. 启用震动编辑 — creates/locates the `HAPTICS` track
2. 插入瞬态 — drops a 25 ms sine item at the cursor (drag to lengthen)
3. 启动手机服务器 — launches `serve-haptics.bat` on the export folder and
   shows the exact URL to type into the phone (detected from `ipconfig`)
4. 试发送选中 — exports only the selected items (no dialog), for
   auditioning a single event on the phone
5. 导出到手机 — full export (time selection / everything), confirms the
   folder first

Below the buttons: a live list of the current haptic events
(time/type/intensity/sharpness); clicking a row selects that item in the
arrange view, ready for 试发送选中.

Install: Actions → Show action list → New action → Load ReaScript → pick
`ReaperHaptics_Panel.lua`, then right-click a toolbar → Customize toolbar →
add that action as a button. Optional keyboard entry points (same logic,
via `ReaperHaptics_Core.lua`): `ReaperHaptics_InsertTransient.lua` on `T`,
`ReaperHaptics_Export.lua` on `Ctrl+Shift+H`.

Authoring model — one media item per haptic event on a track named `HAPTICS`.
Build items from
[`scripts/reaper/reference-sine.wav`](scripts/reaper/reference-sine.wav)
(full-scale 200 Hz mono, loops seamlessly): insert it once, then
copy/trim/stretch — items keep a volume handle **and** the pattern is audible
in REAPER. Empty items work too, but they have no volume handle — write
`i=0.6` in the item note instead (defaults to 1.0).

| Item property                    | Haptic meaning                          |
| -------------------------------- | --------------------------------------- |
| position                         | event start time                        |
| length < 150 ms                  | `HapticTransient`                       |
| length ≥ 150 ms                  | `HapticContinuous` (duration = length)  |
| item volume × take volume        | intensity 0–1 (1.0 = 0 dB, clamped)     |
| `i=0.6` in take name / item note | intensity override (wins over volume)   |
| `s=0.7` in take name / item note | sharpness override (default: intensity) |
| `type=t` / `type=c` in name/note | force transient / continuous            |

Scope: with a time selection, items **starting** inside it, times relative
to the selection start; without one, all items, relative to the first item.
Export warnings (clamped volumes, sub-20 ms transient gaps, >30 s
continuous) land in the REAPER console.

## 1. CLI validation (on the REAPER/Windows machine)

```powershell
# one-time setup, repo root
npm install

# validate one or more files (AHAP or HapticEvent[] JSON, auto-detected)
npm run validate:ahap -- path\to\my-effect.ahap
node scripts/validate-ahap.js --json path\to\my-effect.ahap   # machine-readable
```

- Exit code `0` = no errors (warnings allowed), `1` = errors found.
- Errors: invalid JSON, wrong shapes, intensity/sharpness outside 0–1,
  negative times, missing/over-30s continuous durations.
- Warnings: transients closer than ~20 ms, parameter curves / audio events /
  envelope parameters (dropped by the preview path), missing explicit
  intensity/sharpness.

Verified on this machine: `npm test` (94 tests) and the CLI run against the
three sample files in `example/ios/HapticFeedbackExample/haptics/` all pass.

## 2. Fast iteration loop (no rebuild per file change)

`playAHAP` only reads from the app bundle → rebuild per change. The bench tab
instead loads AHAP JSON at runtime and converts it to `triggerPattern`:

1. On the Windows/REAPER machine, serve the export folder. Easiest: copy
   [`scripts/serve-haptics.bat`](scripts/serve-haptics.bat) into the folder
   and double-click it (or drag the folder onto it) — it finds python,
   starts the server and prints the exact URL to type on the phone.
   Manual equivalent:

   ```powershell
   cd D:\path\to\reaper\haptics-export
   python -m http.server 8765
   ```

   Every designer runs this in **their own** export folder on their own
   machine — nothing is shared or fixed. Team convention: always export the
   pattern currently being auditioned as **`preview.ahap`**, so each phone's
   URL never changes after the first setup.

2. Phone and PC on the same LAN. In the app's **REAPER Bench** tab, enter
   `http://<pc-ip>:8765/preview.ahap` (the bat prints this; the app
   remembers it).
3. Tap **Fetch & Play**, or enable **Watch** — the app polls every second and
   automatically re-validates + replays whenever REAPER re-exports the file.
4. The report card shows errors/warnings and a timeline (blue ticks =
   transients, orange blocks = continuous, height = intensity, opacity =
   sharpness).

The paste-in box does the same for JSON copied by hand. Both accept AHAP
objects (times in **seconds**) and `HapticEvent[]` arrays (times in
**milliseconds**), auto-detected by the JSON root type.

If the fetch fails on iOS with an ATS error: the example app's Info.plist
already sets `NSAllowsLocalNetworking`, and plain-IP URLs are exempt from ATS,
so a plain `http://192.168.x.x` URL should work as-is. If Apple tightens this
in a future iOS release, add `NSAllowsArbitraryLoads` to the **debug** app's
Info.plist.

### Preview-path fidelity (important)

The bench tab's playback is a **preview**: AHAP → `HapticEvent[]` →
`triggerPattern`. Under the hood iOS `triggerPattern` builds the same
`CHHapticEvent` objects Core Haptics builds from a file, so for patterns that
only contain `HapticTransient`/`HapticContinuous` with static
`HapticIntensity`/`HapticSharpness` — i.e. everything the current REAPER
exporter emits — the preview is effectively 1:1.

Dropped by the preview path (the validator warns about each occurrence):

- `ParameterCurve` entries (planned v2 of the REAPER exporter),
- audio events (`AudioCustom`/`AudioContinuous`),
- envelope event parameters (`AttackTime`, `DecayTime`, `ReleaseTime`,
  `Sustained`),
- events without explicit intensity/sharpness feel different (preview
  defaults to 0.5; Core Haptics has its own defaults — always export both
  parameters explicitly).

For bit-exact playback (needed once parameter curves arrive), bundle the file
and use the **AHAP Files** section in the Library Demo tab (`playAHAP`).

## 3. True `playAHAP` playback — Xcode bundle steps (on the Mac)

`.ahap` files must be inside the app bundle, in a `haptics/` folder or at the
bundle root. The example project already bundles
`example/ios/HapticFeedbackExample/haptics/` as a **folder reference**, so:

1. Copy your `.ahap` files into `example/ios/HapticFeedbackExample/haptics/`.
   Because it is a blue folder reference (not a yellow group), files dropped
   into it on disk are picked up automatically — no Xcode clicking needed.
2. Rebuild and run on the device — **install repo-root deps first**; the
   example depends on `file:../`, and installing it runs the root `prepare`
   script, which needs the root `node_modules`:

   ```bash
   npm install                # repo root first
   cd example && npm install
   cd ios && pod install      # or: bundle install && bundle exec pod install
   ```

   Then open `HapticFeedbackExample.xcworkspace` in Xcode, select your
   device, Run. (Or `npm run ios -- --device` from `example/`.)

3. In the app: **Library Demo tab → AHAP Files**. To add your own entries to
   that list, edit `AHAP_FILES` in `example/App.tsx` — `file` is the file
   name inside `haptics/`, `fallback` is the Android pattern.
4. Play from code: `playAHAP('my-effect.ahap')` (name only, no path), or
   cross-platform `playHaptic('my-effect.ahap', fallbackEvents)`.

If you ever add a haptics folder to a _new_ Xcode project: File → Add Files
to "<target>" → select the `haptics` folder → choose **Create folder
references** (blue icon) → check your app target under "Add to targets".
Verify under Build Phases → Copy Bundle Resources that the folder is listed.

Reminder: Core Haptics needs a **physical iPhone (iOS 13+)** — the iOS
Simulator does not vibrate; `isSupported()` returns false there.

### Packaging for designers: build Release

Debug builds show the black "Connect to Metro to develop JavaScript"
banner (it waits for a dev server) and start slowly (interpreted JS, dev
runtime). A **Release** build removes the banner and starts several times
faster — use it for any build handed to designers:

1. After `git pull`: `cd example && npm install && cd ios && pod install`
   (dependencies were trimmed; pod install removes the unused ones).
2. Xcode → Product → Scheme → Edit Scheme… → Run → Build Configuration →
   **Release** → close, then run on the device as usual.
3. The app is then fully standalone — no Metro, no LAN needed for launch
   (the bench URL fetch of course still needs the LAN).

Signing lifetime applies as usual: free Apple ID builds stop launching
after 7 days; a paid team certificate (or TestFlight) lasts much longer.

## 4. Android fallback

The same bench tab runs on Android unchanged: both AHAP (converted) and
`HapticEvent[]` payloads play through `triggerPattern`, which maps to
`VibrationEffect` amplitudes there. Author once in REAPER, export both
formats, load each on one device — that is the side-by-side comparison.
Android has no sharpness axis; expect continuous events to feel buzzier than
the iPhone's Taptic Engine rendering.

## 5. REAPER exporter integration notes

- The second export target should emit `HapticEvent[]` JSON: an array of
  `{ "time": <ms>, "type": "transient" | "continuous", "duration": <ms,
continuous only>, "intensity": 0–1, "sharpness": 0–1 }` — matching
  `HapticEvent` in [`src/types.ts`](src/types.ts). The `AhapType` definitions
  in the same file are the schema for the `.ahap` target.
- Always write explicit `HapticIntensity` and `HapticSharpness` (see fidelity
  notes above).
- Keep transients ≥ 20 ms apart (empirical floor: ~23 ms gaps still read as
  distinct pulses on device; Apple's 100 ms guidance is conservative)
  (`MIN_TRANSIENT_SPACING_MS`); the validator flags violations.
- Continuous events must be > 0 s and ≤ 30 s (Core Haptics hard limit).
