import type { AhapType, HapticEvent } from "../types";

/**
 * Utilities for working with Apple Haptic and Audio Pattern (AHAP) data in
 * plain TypeScript — no native code involved.
 *
 * - `validateAhap()` checks a parsed JSON value (or a raw JSON string)
 *   against the `AhapType` schema and reports out-of-range values and
 *   playback pitfalls before the file ever reaches a device.
 * - `ahapToHapticEvents()` converts an AHAP pattern into the cross-platform
 *   `HapticEvent[]` format understood by `triggerPattern()`. This enables a
 *   no-rebuild "preview" playback path: load AHAP JSON at runtime, convert,
 *   and play — instead of bundling the file and calling `playAHAP`.
 * - `validateHapticEvents()` performs the same kind of checks on a
 *   `HapticEvent[]` JSON payload (the Android-friendly second export format).
 *
 * Time bases: AHAP uses **seconds** (float), `HapticEvent[]` uses
 * **milliseconds**. The conversion happens exclusively inside
 * `ahapToHapticEvents()` — everything named `*Seconds`/`Time` upstream of it
 * is seconds, everything named `time`/`duration` downstream is milliseconds.
 *
 * Preview-path fidelity: `triggerPattern` renders `HapticTransient` and
 * `HapticContinuous` events with static `HapticIntensity`/`HapticSharpness`
 * exactly like Core Haptics renders them from a file. Anything else —
 * `ParameterCurve`s, audio events, envelope parameters (AttackTime etc.) —
 * cannot be expressed as `HapticEvent`s and is dropped by the converter
 * (with a corresponding validator warning). Patterns that use those features
 * must be bundled and played via `playAHAP` for faithful playback.
 */

/**
 * Minimum spacing between transient events (ms) for the hardware to render
 * them as distinct pulses. Matches `TRANSIENT_DURATION_MS` in pattern.ts.
 */
export const MIN_TRANSIENT_SPACING_MS = 100;

/** Core Haptics rejects continuous events longer than 30 seconds. */
export const MAX_CONTINUOUS_DURATION_S = 30;

export interface AhapIssue {
  severity: "error" | "warning";
  /** JSON path of the offending value, e.g. `Pattern[3].Event.Time` */
  path: string;
  message: string;
}

export interface AhapValidationResult {
  /** true when there are no `error`-severity issues (warnings are allowed) */
  valid: boolean;
  issues: AhapIssue[];
  /** The parsed AHAP object, present when the input was structurally usable */
  ahap?: AhapType;
}

const KNOWN_EVENT_TYPES = [
  "HapticTransient",
  "HapticContinuous",
  "AudioCustom",
  "AudioContinuous",
];
const KNOWN_EVENT_PARAMETER_IDS = [
  "HapticIntensity",
  "HapticSharpness",
  "AttackTime",
  "DecayTime",
  "ReleaseTime",
  "Sustained",
  "AudioVolume",
  "AudioPitch",
  "AudioPan",
  "AudioBrightness",
];
/** Event parameters the preview path (triggerPattern) can actually render. */
const PREVIEWABLE_PARAMETER_IDS = ["HapticIntensity", "HapticSharpness"];

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/**
 * Validate an AHAP pattern against the `AhapType` schema and flag values
 * that will misbehave on a device.
 *
 * Accepts either an already-parsed object or a raw JSON string.
 *
 * Errors (make the pattern invalid):
 * - malformed JSON / wrong top-level shape / missing `Pattern` array
 * - unknown `EventType`
 * - missing or negative `Time`, missing/non-positive `EventDuration`
 * - `HapticIntensity` / `HapticSharpness` outside 0–1
 * - continuous events longer than 30 s (Core Haptics limit)
 *
 * Warnings (playable, but check the report):
 * - transient events spaced closer than {@link MIN_TRANSIENT_SPACING_MS} —
 *   the actuator cannot render them as distinct pulses
 * - features the converted-`triggerPattern` preview path drops: parameter
 *   curves, audio events, envelope parameters (AttackTime, DecayTime, …)
 * - events without explicit intensity/sharpness (preview defaults to 0.5,
 *   Core Haptics uses its own defaults — always write them explicitly)
 *
 * @example
 * const report = validateAhap(jsonStringFromReaper);
 * if (!report.valid) console.warn(report.issues);
 */
export function validateAhap(input: unknown): AhapValidationResult {
  const issues: AhapIssue[] = [];
  const error = (path: string, message: string) =>
    issues.push({ severity: "error", path, message });
  const warn = (path: string, message: string) =>
    issues.push({ severity: "warning", path, message });

  let data: unknown = input;
  if (typeof input === "string") {
    try {
      data = JSON.parse(input);
    } catch (e) {
      error("$", `not valid JSON: ${(e as Error).message}`);
      return { valid: false, issues };
    }
  }

  if (!isObject(data)) {
    error("$", "AHAP root must be a JSON object");
    return { valid: false, issues };
  }

  if (
    data.Version !== undefined &&
    data.Version !== 1 &&
    data.Version !== 1.0
  ) {
    warn(
      "Version",
      `unexpected Version ${JSON.stringify(data.Version)} (expected 1.0)`,
    );
  }

  if (!Array.isArray(data.Pattern)) {
    error("Pattern", "missing required `Pattern` array");
    return { valid: false, issues };
  }

  // seconds; collected for the spacing check
  const transientTimes: { time: number; path: string }[] = [];

  data.Pattern.forEach((entry: unknown, i: number) => {
    const base = `Pattern[${i}]`;
    if (!isObject(entry)) {
      error(base, "pattern entry must be an object");
      return;
    }

    if (entry.ParameterCurve !== undefined) {
      warn(
        `${base}.ParameterCurve`,
        "parameter curves are not representable as HapticEvents — the preview " +
          "(triggerPattern) path ignores them; use bundled playAHAP for faithful playback",
      );
      const curve = entry.ParameterCurve;
      if (isObject(curve)) {
        if (!isFiniteNumber(curve.Time) || curve.Time < 0) {
          error(
            `${base}.ParameterCurve.Time`,
            "Time must be a number >= 0 (seconds)",
          );
        }
        if (!Array.isArray(curve.ParameterCurveControlPoints)) {
          error(
            `${base}.ParameterCurve.ParameterCurveControlPoints`,
            "missing control point array",
          );
        }
      } else {
        error(`${base}.ParameterCurve`, "ParameterCurve must be an object");
      }
      return;
    }

    if (!isObject(entry.Event)) {
      error(
        base,
        "pattern entry must contain an `Event` or `ParameterCurve` object",
      );
      return;
    }
    const event = entry.Event;
    const eventPath = `${base}.Event`;

    const eventType = event.EventType;
    if (
      typeof eventType !== "string" ||
      !KNOWN_EVENT_TYPES.includes(eventType)
    ) {
      error(
        `${eventPath}.EventType`,
        `unknown EventType ${JSON.stringify(eventType)}`,
      );
      return;
    }
    const isHaptic =
      eventType === "HapticTransient" || eventType === "HapticContinuous";
    if (!isHaptic) {
      warn(
        `${eventPath}.EventType`,
        `${eventType} (audio) events are ignored by both the preview path and the Android fallback`,
      );
    }

    if (!isFiniteNumber(event.Time)) {
      error(`${eventPath}.Time`, "Time must be a number (seconds)");
    } else if (event.Time < 0) {
      error(`${eventPath}.Time`, `Time must be >= 0, got ${event.Time}`);
    } else if (eventType === "HapticTransient") {
      transientTimes.push({ time: event.Time, path: `${eventPath}.Time` });
    }

    if (eventType === "HapticContinuous") {
      if (!isFiniteNumber(event.EventDuration)) {
        error(
          `${eventPath}.EventDuration`,
          "HapticContinuous requires a numeric EventDuration (seconds)",
        );
      } else if (event.EventDuration <= 0) {
        error(
          `${eventPath}.EventDuration`,
          `EventDuration must be > 0, got ${event.EventDuration}`,
        );
      } else if (event.EventDuration > MAX_CONTINUOUS_DURATION_S) {
        error(
          `${eventPath}.EventDuration`,
          `EventDuration ${event.EventDuration}s exceeds the Core Haptics limit of ${MAX_CONTINUOUS_DURATION_S}s`,
        );
      }
    } else if (
      event.EventDuration !== undefined &&
      eventType === "HapticTransient"
    ) {
      warn(
        `${eventPath}.EventDuration`,
        "EventDuration has no effect on HapticTransient events",
      );
    }

    if (!isHaptic) return;

    const params = event.EventParameters;
    const seen: string[] = [];
    if (params !== undefined) {
      if (!Array.isArray(params)) {
        error(
          `${eventPath}.EventParameters`,
          "EventParameters must be an array",
        );
        return;
      }
      params.forEach((param: unknown, j: number) => {
        const paramPath = `${eventPath}.EventParameters[${j}]`;
        if (!isObject(param)) {
          error(paramPath, "event parameter must be an object");
          return;
        }
        const id = param.ParameterID;
        const value = param.ParameterValue;
        if (typeof id !== "string" || !KNOWN_EVENT_PARAMETER_IDS.includes(id)) {
          warn(paramPath, `unknown ParameterID ${JSON.stringify(id)}`);
          return;
        }
        seen.push(id);
        if (!isFiniteNumber(value)) {
          error(`${paramPath}.ParameterValue`, `${id} value must be a number`);
          return;
        }
        if (
          (id === "HapticIntensity" || id === "HapticSharpness") &&
          (value < 0 || value > 1)
        ) {
          error(
            `${paramPath}.ParameterValue`,
            `${id} must be within 0–1, got ${value}`,
          );
        }
        if (!PREVIEWABLE_PARAMETER_IDS.includes(id)) {
          warn(
            paramPath,
            `${id} is not representable as a HapticEvent — the preview (triggerPattern) path ignores it`,
          );
        }
      });
    }
    for (const required of PREVIEWABLE_PARAMETER_IDS) {
      if (!seen.includes(required)) {
        warn(
          eventPath,
          `no explicit ${required}: the preview path defaults to 0.5 while playAHAP uses ` +
            "Core Haptics defaults — set it explicitly so both paths feel the same",
        );
      }
    }
  });

  transientTimes.sort((a, b) => a.time - b.time);
  transientTimes.forEach((curr, i) => {
    const prev = transientTimes[i - 1];
    if (!prev) return;
    const gapMs = (curr.time - prev.time) * 1000;
    if (gapMs < MIN_TRANSIENT_SPACING_MS - 0.5) {
      warn(
        curr.path,
        `transient only ${Math.round(gapMs)}ms after the previous one — the actuator needs ` +
          `~${MIN_TRANSIENT_SPACING_MS}ms to render distinct pulses`,
      );
    }
  });

  const valid = !issues.some((issue) => issue.severity === "error");
  return { valid, issues, ahap: data as unknown as AhapType };
}

/**
 * Convert an AHAP pattern to the cross-platform `HapticEvent[]` format used
 * by `triggerPattern()`. **AHAP times are seconds; the returned events are
 * milliseconds.**
 *
 * Only `HapticTransient` and `HapticContinuous` events survive the
 * conversion; parameter curves, audio events and envelope parameters are
 * dropped (run `validateAhap()` first to see what, if anything, gets lost).
 * Events missing an explicit intensity/sharpness are passed through without
 * one, so `triggerPattern`'s 0.5 defaults apply.
 *
 * @example
 * const report = validateAhap(json);
 * if (report.valid && report.ahap) {
 *   triggerPattern(ahapToHapticEvents(report.ahap));
 * }
 */
export function ahapToHapticEvents(ahap: AhapType): HapticEvent[] {
  const events: HapticEvent[] = [];

  for (const entry of ahap.Pattern ?? []) {
    if (!("Event" in entry) || !isObject(entry.Event)) continue;
    const event = entry.Event;
    if (
      event.EventType !== "HapticTransient" &&
      event.EventType !== "HapticContinuous"
    ) {
      continue;
    }
    if (!isFiniteNumber(event.Time)) continue;

    let intensity: number | undefined;
    let sharpness: number | undefined;
    if (Array.isArray(event.EventParameters)) {
      for (const param of event.EventParameters) {
        if (!isObject(param) || !isFiniteNumber(param.ParameterValue)) continue;
        if (param.ParameterID === "HapticIntensity")
          intensity = param.ParameterValue;
        else if (param.ParameterID === "HapticSharpness")
          sharpness = param.ParameterValue;
      }
    }

    const hapticEvent: HapticEvent = { time: event.Time * 1000 };
    if (event.EventType === "HapticContinuous") {
      hapticEvent.type = "continuous";
      hapticEvent.duration = isFiniteNumber(event.EventDuration)
        ? event.EventDuration * 1000
        : undefined;
    } else {
      hapticEvent.type = "transient";
    }
    if (intensity !== undefined) hapticEvent.intensity = intensity;
    if (sharpness !== undefined) hapticEvent.sharpness = sharpness;
    events.push(hapticEvent);
  }

  return events.sort((a, b) => a.time - b.time);
}

/**
 * Validate a `HapticEvent[]` JSON payload (times in **milliseconds**) — the
 * cross-platform second export format that pairs with `triggerPattern()`.
 *
 * Accepts either an already-parsed value or a raw JSON string. Applies the
 * same range and transient-spacing checks as `validateAhap()`.
 */
export function validateHapticEvents(input: unknown): {
  valid: boolean;
  issues: AhapIssue[];
  events?: HapticEvent[];
} {
  const issues: AhapIssue[] = [];
  const error = (path: string, message: string) =>
    issues.push({ severity: "error", path, message });
  const warn = (path: string, message: string) =>
    issues.push({ severity: "warning", path, message });

  let data: unknown = input;
  if (typeof input === "string") {
    try {
      data = JSON.parse(input);
    } catch (e) {
      error("$", `not valid JSON: ${(e as Error).message}`);
      return { valid: false, issues };
    }
  }

  if (!Array.isArray(data)) {
    error("$", "HapticEvent payload must be a JSON array");
    return { valid: false, issues };
  }

  const transientTimes: { time: number; path: string }[] = [];

  data.forEach((event: unknown, i: number) => {
    const base = `[${i}]`;
    if (!isObject(event)) {
      error(base, "event must be an object");
      return;
    }
    if (!isFiniteNumber(event.time)) {
      error(`${base}.time`, "time must be a number (milliseconds)");
    } else if (event.time < 0) {
      error(`${base}.time`, `time must be >= 0, got ${event.time}`);
    }
    const type = event.type ?? "transient";
    if (type !== "transient" && type !== "continuous") {
      error(
        `${base}.type`,
        `type must be "transient" or "continuous", got ${JSON.stringify(event.type)}`,
      );
    } else if (type === "continuous") {
      if (event.duration === undefined) {
        warn(
          `${base}.duration`,
          "continuous event without duration falls back to 100ms on iOS",
        );
      } else if (!isFiniteNumber(event.duration) || event.duration <= 0) {
        error(
          `${base}.duration`,
          `duration must be a number > 0 (milliseconds), got ${JSON.stringify(event.duration)}`,
        );
      }
    } else if (isFiniteNumber(event.time)) {
      transientTimes.push({ time: event.time, path: `${base}.time` });
    }
    for (const key of ["intensity", "sharpness"] as const) {
      const value = event[key];
      if (value === undefined) {
        warn(
          `${base}.${key}`,
          `no explicit ${key} — triggerPattern defaults to 0.5`,
        );
      } else if (!isFiniteNumber(value)) {
        error(`${base}.${key}`, `${key} must be a number`);
      } else if (value < 0 || value > 1) {
        error(`${base}.${key}`, `${key} must be within 0–1, got ${value}`);
      }
    }
  });

  transientTimes.sort((a, b) => a.time - b.time);
  transientTimes.forEach((curr, i) => {
    const prev = transientTimes[i - 1];
    if (!prev) return;
    const gapMs = curr.time - prev.time;
    if (gapMs < MIN_TRANSIENT_SPACING_MS - 0.5) {
      warn(
        curr.path,
        `transient only ${Math.round(gapMs)}ms after the previous one — the actuator needs ` +
          `~${MIN_TRANSIENT_SPACING_MS}ms to render distinct pulses`,
      );
    }
  });

  const valid = !issues.some((issue) => issue.severity === "error");
  return valid
    ? { valid, issues, events: data as HapticEvent[] }
    : { valid, issues };
}
