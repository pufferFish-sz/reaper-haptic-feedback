import {
  ahapToHapticEvents,
  validateAhap,
  validateHapticEvents,
} from "../utils/ahap";
import type { AhapType } from "../types";

const heartbeat: AhapType = {
  Version: 1.0,
  Pattern: [
    {
      Event: {
        EventType: "HapticTransient",
        Time: 0.0,
        EventParameters: [
          { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
          { ParameterID: "HapticSharpness", ParameterValue: 0.3 },
        ],
      },
    },
    {
      Event: {
        EventType: "HapticTransient",
        Time: 0.15,
        EventParameters: [
          { ParameterID: "HapticIntensity", ParameterValue: 1.0 },
          { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
        ],
      },
    },
  ],
};

describe("validateAhap", () => {
  it("accepts a well-formed pattern with no issues", () => {
    const result = validateAhap(heartbeat);
    expect(result.valid).toBe(true);
    expect(result.issues).toHaveLength(0);
    expect(result.ahap).toBe(heartbeat);
  });

  it("accepts a raw JSON string", () => {
    const result = validateAhap(JSON.stringify(heartbeat));
    expect(result.valid).toBe(true);
    expect(result.ahap).toEqual(heartbeat);
  });

  it("rejects malformed JSON strings", () => {
    const result = validateAhap("{ not json");
    expect(result.valid).toBe(false);
    expect(result.issues[0]).toMatchObject({ severity: "error", path: "$" });
  });

  it("rejects non-object roots and missing Pattern", () => {
    expect(validateAhap([1, 2]).valid).toBe(false);
    expect(validateAhap({ Version: 1.0 }).valid).toBe(false);
  });

  it("rejects out-of-range intensity and sharpness", () => {
    const result = validateAhap({
      Pattern: [
        {
          Event: {
            EventType: "HapticTransient",
            Time: 0,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 1.4 },
              { ParameterID: "HapticSharpness", ParameterValue: -0.2 },
            ],
          },
        },
      ],
    });
    expect(result.valid).toBe(false);
    const errors = result.issues.filter((i) => i.severity === "error");
    expect(errors).toHaveLength(2);
    expect(errors[0]?.path).toContain("EventParameters[0]");
    expect(errors[1]?.path).toContain("EventParameters[1]");
  });

  it("rejects negative times and non-positive continuous durations", () => {
    const result = validateAhap({
      Pattern: [
        {
          Event: {
            EventType: "HapticTransient",
            Time: -0.5,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
              { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
            ],
          },
        },
        {
          Event: {
            EventType: "HapticContinuous",
            Time: 0,
            EventDuration: 0,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
              { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
            ],
          },
        },
      ],
    });
    expect(result.valid).toBe(false);
    expect(
      result.issues.filter((i) => i.severity === "error").map((i) => i.path),
    ).toEqual(["Pattern[0].Event.Time", "Pattern[1].Event.EventDuration"]);
  });

  it("rejects continuous events longer than the 30s Core Haptics limit", () => {
    const result = validateAhap({
      Pattern: [
        {
          Event: {
            EventType: "HapticContinuous",
            Time: 0,
            EventDuration: 31,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
              { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
            ],
          },
        },
      ],
    });
    expect(result.valid).toBe(false);
    expect(result.issues[0]?.message).toContain("30");
  });

  it("warns about transients spaced closer than the 20ms floor", () => {
    const makeTransient = (time: number) => ({
      Event: {
        EventType: "HapticTransient",
        Time: time,
        EventParameters: [
          { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
          { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
        ],
      },
    });
    // deliberately out of order — the check must sort by time first
    const result = validateAhap({
      Pattern: [makeTransient(0.25), makeTransient(0), makeTransient(0.01)],
    });
    expect(result.valid).toBe(true); // warning, not error
    const spacing = result.issues.filter((i) =>
      i.message.includes("distinct pulses"),
    );
    expect(spacing).toHaveLength(1);
    expect(spacing[0]?.message).toContain("10ms");
  });

  it("warns that parameter curves are dropped by the preview path", () => {
    const result = validateAhap({
      Pattern: [
        ...heartbeat.Pattern,
        {
          ParameterCurve: {
            ParameterID: "HapticIntensityControl",
            Time: 0,
            ParameterCurveControlPoints: [
              { Time: 0, ParameterValue: 1 },
              { Time: 0.5, ParameterValue: 0 },
            ],
          },
        },
      ],
    });
    expect(result.valid).toBe(true);
    expect(
      result.issues.some(
        (i) =>
          i.severity === "warning" && i.path === "Pattern[2].ParameterCurve",
      ),
    ).toBe(true);
  });

  it("warns about audio events and envelope parameters", () => {
    const result = validateAhap({
      Pattern: [
        {
          Event: {
            EventType: "AudioCustom",
            Time: 0,
            EventWaveformPath: "click.wav",
            EventParameters: [],
          },
        },
        {
          Event: {
            EventType: "HapticContinuous",
            Time: 0,
            EventDuration: 1,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 0.5 },
              { ParameterID: "HapticSharpness", ParameterValue: 0.5 },
              { ParameterID: "AttackTime", ParameterValue: 0.2 },
            ],
          },
        },
      ],
    });
    expect(result.valid).toBe(true);
    expect(result.issues.some((i) => i.message.includes("AudioCustom"))).toBe(
      true,
    );
    expect(result.issues.some((i) => i.message.includes("AttackTime"))).toBe(
      true,
    );
  });

  it("warns when intensity or sharpness is not explicit", () => {
    const result = validateAhap({
      Pattern: [{ Event: { EventType: "HapticTransient", Time: 0 } }],
    });
    expect(result.valid).toBe(true);
    const missing = result.issues.filter((i) =>
      i.message.includes("no explicit"),
    );
    expect(missing).toHaveLength(2);
  });

  it("rejects unknown event types", () => {
    const result = validateAhap({
      Pattern: [{ Event: { EventType: "HapticBogus", Time: 0 } }],
    });
    expect(result.valid).toBe(false);
  });
});

describe("ahapToHapticEvents", () => {
  it("converts seconds to milliseconds", () => {
    const events = ahapToHapticEvents(heartbeat);
    expect(events).toEqual([
      { time: 0, type: "transient", intensity: 0.5, sharpness: 0.3 },
      { time: 150, type: "transient", intensity: 1.0, sharpness: 0.5 },
    ]);
  });

  it("converts continuous events with duration in milliseconds", () => {
    const events = ahapToHapticEvents({
      Pattern: [
        {
          Event: {
            EventType: "HapticContinuous",
            Time: 0.5,
            EventDuration: 1.25,
            EventParameters: [
              { ParameterID: "HapticIntensity", ParameterValue: 0.8 },
              { ParameterID: "HapticSharpness", ParameterValue: 0.2 },
            ],
          },
        },
      ],
    });
    expect(events).toEqual([
      {
        time: 500,
        type: "continuous",
        duration: 1250,
        intensity: 0.8,
        sharpness: 0.2,
      },
    ]);
  });

  it("drops parameter curves and audio events, keeps haptic events", () => {
    const events = ahapToHapticEvents({
      Pattern: [
        {
          ParameterCurve: {
            ParameterID: "HapticIntensityControl",
            Time: 0,
            ParameterCurveControlPoints: [],
          },
        },
        {
          Event: {
            EventType: "AudioCustom",
            Time: 0,
            EventWaveformPath: "click.wav",
            EventParameters: [],
          },
        },
        ...heartbeat.Pattern,
      ],
    });
    expect(events).toHaveLength(2);
    expect(events.every((e) => e.type === "transient")).toBe(true);
  });

  it("sorts events by time", () => {
    const events = ahapToHapticEvents({
      Pattern: [
        {
          Event: {
            EventType: "HapticTransient",
            Time: 0.3,
            EventParameters: [],
          },
        },
        {
          Event: {
            EventType: "HapticTransient",
            Time: 0.1,
            EventParameters: [],
          },
        },
      ],
    });
    expect(events.map((e) => e.time)).toEqual([100, 300]);
  });

  it("omits intensity/sharpness when the AHAP has none (native defaults apply)", () => {
    const events = ahapToHapticEvents({
      Pattern: [
        {
          Event: { EventType: "HapticTransient", Time: 0, EventParameters: [] },
        },
      ],
    });
    expect(events[0]?.intensity).toBeUndefined();
    expect(events[0]?.sharpness).toBeUndefined();
  });
});

describe("validateHapticEvents", () => {
  const good = [
    { time: 0, type: "transient", intensity: 0.5, sharpness: 0.5 },
    {
      time: 200,
      type: "continuous",
      duration: 500,
      intensity: 1,
      sharpness: 0,
    },
  ];

  it("accepts a valid HapticEvent array (object or JSON string)", () => {
    expect(validateHapticEvents(good).valid).toBe(true);
    const fromString = validateHapticEvents(JSON.stringify(good));
    expect(fromString.valid).toBe(true);
    expect(fromString.events).toEqual(good);
  });

  it("rejects non-array payloads", () => {
    expect(validateHapticEvents(heartbeat).valid).toBe(false);
  });

  it("rejects out-of-range values and bad durations", () => {
    const result = validateHapticEvents([
      { time: -1, intensity: 2, sharpness: 0.5 },
      {
        time: 0,
        type: "continuous",
        duration: -5,
        intensity: 0.5,
        sharpness: 0.5,
      },
    ]);
    expect(result.valid).toBe(false);
    expect(result.events).toBeUndefined();
    const paths = result.issues
      .filter((i) => i.severity === "error")
      .map((i) => i.path);
    expect(paths).toEqual(["[0].time", "[0].intensity", "[1].duration"]);
  });

  it("warns about transients closer than the 20ms floor (times are ms)", () => {
    const result = validateHapticEvents([
      { time: 0, intensity: 0.5, sharpness: 0.5 },
      { time: 10, intensity: 0.5, sharpness: 0.5 },
    ]);
    expect(result.valid).toBe(true);
    expect(
      result.issues.some((i) => i.message.includes("distinct pulses")),
    ).toBe(true);
  });
});
