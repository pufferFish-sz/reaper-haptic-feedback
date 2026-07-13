# Project Context: Haptics Pipeline — Device Testing Side

> Feed this document to Claude Code from inside the cloned `react-native-haptic-feedback` repo. It explains who I am, what the larger pipeline is, why this repo was chosen, and what I want to accomplish here.

## Who I am / background

I am a game audio designer and composer. I design haptic feedback for game sound effects (mobile-focused). My team has prior experience with Unity, NiceVibrations (Feel plugin, `.haptic` files), and an in-house vibration system. I am comfortable with REAPER scripting workflows but am not primarily a React Native developer — explain RN/Xcode-specific steps clearly when they come up.

## The larger pipeline (upstream, already specced separately)

I am building a haptics **authoring** workflow inside REAPER:

- A dedicated `HAPTICS` track where each media item is one haptic event ("items-as-rectangles").
- Item position = start time, item length = duration, item volume on a full-scale reference sine wave = intensity (0–1), sharpness defaults to intensity with a per-item `s=X` take-name override.
- A ReaScript exporter converts the items in a time selection into an Apple **`.ahap`** file (`HapticContinuous` + `HapticTransient` events).

That REAPER exporter is a **separate project**. This repo is the **downstream half**: playing and validating the exported files on real devices.

## My intentions in THIS repo

1. **Validate REAPER-exported `.ahap` files on a physical iPhone.** I need a fast, repeatable way to feel the haptics I author in REAPER, so I can iterate on the design (like ReaHaptic's phone-preview workflow, but for my own AHAP pipeline).
2. **Understand and reuse the library's data model.** Its `HapticEvent[]` format (`time` ms, `type` transient/continuous, `duration` ms, `intensity` 0–1, `sharpness` 0–1) is structurally identical to my REAPER exporter's internal model. I may add a second export target in REAPER that emits this format directly.
3. **Prepare an Android path.** AHAP is iOS-only. This library's `playHaptic(ahapFile, fallbackPattern)` plays `.ahap` on iOS and falls back to `triggerPattern` on Android — which means one REAPER authoring pass can serve both platforms if I export both formats.
4. **Eventually inform game integration.** What I learn here about intensity/sharpness ranges and transient spacing (the library documents a ~100 ms minimum interval for distinct pulses) feeds back into my authoring guidelines.

## Why react-native-haptic-feedback (vs. alternatives)

- **It plays `.ahap` files directly** (`playAHAP`) via Core Haptics — exactly the file my REAPER tool outputs. I don't need to write any Swift.
- **Actively maintained** (v3.0.0, 2026; ~1k stars) with modern RN support, versus `expo-ahap`, which is a small unmaintained experiment (no releases) — though expo-ahap's `Player` accepts an AHAP pattern as a runtime JS object, which is a useful reference for hot-reloading patterns without rebuilding.
- **Cross-platform story**: Android fallback via `triggerPattern`/`playHaptic` matters because our games ship on Android too; a pure-iOS tool would only solve half my problem.
- **Testing conveniences**: companion "Haptic Feedback Tryout" app, Jest mocks, pattern notation for quick A/B reference feels.
- Its `AhapType` TypeScript definitions double as a schema reference for my REAPER exporter's JSON output.

## What I want Claude Code to help me build (execution)

Build a minimal **haptic test-bench app** in/alongside this repo (using the `example` app as a starting point if convenient):

1. **iOS `.ahap` playback screen**: list bundled `.ahap` files from the `haptics/` folder, tap to play via `playAHAP`. Document the Xcode bundle-resource steps for me precisely (I'm on Windows for REAPER but will build on a Mac).
2. **Iteration speed is the top priority.** `playAHAP` only reads from the app bundle, which requires a rebuild per file change — that kills the design loop. Investigate and implement the fastest reload path, in order of preference:
   - Load `.ahap` JSON at runtime (Documents directory / dev-server fetch / paste-in), parse it, and convert to a `triggerPattern` call so no rebuild is needed; or
   - Borrow expo-ahap's approach of passing the parsed AHAP object to a native player.
     Note any fidelity differences between the converted-`triggerPattern` path and true `playAHAP` playback (e.g. parameter curves are not representable as HapticEvents) and clearly label the reload path as "preview" if it's lossy.
3. **Android fallback screen**: play the equivalent `HapticEvent[]` JSON (my REAPER exporter will emit this as a second format) via `triggerPattern`, so I can compare iOS vs Android feel side by side.
4. **A validation utility**: given a `.ahap` file, check JSON validity against the library's `AhapType` definitions and report out-of-range values (times, intensity/sharpness outside 0–1, transients closer than ~100 ms) before I ever get to a device.

## Constraints & notes

- Physical iOS 13+ device required; Core Haptics does not work in the iOS Simulator.
- Keep everything in TypeScript; prefer the library's public API over forking native code unless the runtime-AHAP-loading feature truly requires it.
- Time bases differ: AHAP uses **seconds** (float), `HapticEvent[]` uses **milliseconds** — conversion utilities must be explicit about this.
- My `.ahap` files currently contain only `HapticTransient` and `HapticContinuous` events with `HapticIntensity`/`HapticSharpness` parameters — no audio events, no parameter curves (curves are a planned v2 of the REAPER exporter; keep the test bench forward-compatible with them).

## Implementation status (2026-07-13)

All four deliverables are built — see `TESTBENCH.md` for the full workflow
(CLI usage, LAN hot-reload loop, Xcode bundle steps, fidelity notes):

- `src/utils/ahap.ts`: `validateAhap()` / `validateHapticEvents()` /
  `ahapToHapticEvents()` (seconds→ms), exported from the library root,
  21 unit tests in `src/__tests__/ahap.test.ts`.
- `scripts/validate-ahap.js` + `npm run validate:ahap -- <file>`: pre-device
  validation CLI (transpiles the TS source on the fly; needs `npm install`
  once at the repo root, no build step).
- `example/src/TestBench.tsx`: "REAPER Bench" tab in the example app — URL
  fetch + 1 s watch-mode auto-replay, paste-in JSON, both formats
  auto-detected, validation report, event timeline. Playback is the
  converted-`triggerPattern` preview path (lossless for the current
  transient/continuous-only exports; curves/audio/envelopes are dropped
  with warnings).
- `example/ios` project: `haptics/` was converted from per-file references
  to a blue folder reference — drop `.ahap` files into
  `example/ios/HapticFeedbackExample/haptics/` on disk and rebuild; no
  Xcode clicking needed.
- Known repo quirks: `npm ci` fails (upstream lockfile out of sync — use
  `npm install`); `core.autocrlf=true` makes `npm run lint` report `␍`
  prettier errors repo-wide (pre-existing, not ours); example jest needed
  mocks (`example/jest.setup.js`) and module mappings (`example/jest.config.js`)
  to run at all — `cd example && npm test` now passes.
