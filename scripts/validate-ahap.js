#!/usr/bin/env node
/*
 * Validate .ahap files (or HapticEvent[] .json files) from the command line,
 * before they ever reach a device:
 *
 *   npm run validate:ahap -- path/to/file.ahap [more files...]
 *   node scripts/validate-ahap.js --json path/to/file.ahap
 *
 * Checks JSON validity against the library's AhapType definitions and
 * reports out-of-range values (times, intensity/sharpness outside 0-1,
 * transients closer than the perceivable minimum spacing, ~20 ms). Files
 * whose parsed root is an array are
 * treated as HapticEvent[] payloads (times in milliseconds).
 *
 * The validation logic lives in src/utils/ahap.ts (single source of truth,
 * unit-tested). This script transpiles it on the fly with the `typescript`
 * dev-dependency, so no build step is required — just `npm install` once.
 *
 * Output is plain ASCII on purpose: Windows consoles with a non-UTF-8
 * codepage (e.g. GBK) garble anything fancier.
 */

"use strict";

const fs = require("fs");
const path = require("path");
const Module = require("module");

function loadAhapUtils() {
  const srcPath = path.join(__dirname, "..", "src", "utils", "ahap.ts");
  let ts;
  try {
    ts = require("typescript");
  } catch {
    console.error(
      "error: the `typescript` package is not installed. Run `npm install` in the repo root first.",
    );
    process.exit(2);
  }
  const source = fs.readFileSync(srcPath, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
    },
    fileName: srcPath,
  });
  const mod = new Module(srcPath, module);
  mod.filename = srcPath;
  mod.paths = Module._nodeModulePaths(path.dirname(srcPath));
  mod._compile(transpiled.outputText, srcPath);
  return mod.exports;
}

function summarize(events) {
  const transients = events.filter(
    (e) => (e.type || "transient") === "transient",
  );
  const continuous = events.filter((e) => e.type === "continuous");
  const endTimes = events.map((e) => e.time + (e.duration || 0));
  const totalMs = endTimes.length ? Math.max(...endTimes) : 0;
  let minGapMs = null;
  const times = transients.map((e) => e.time).sort((a, b) => a - b);
  for (let i = 1; i < times.length; i++) {
    const gap = times[i] - times[i - 1];
    if (minGapMs === null || gap < minGapMs) minGapMs = gap;
  }
  return {
    events: events.length,
    transients: transients.length,
    continuous: continuous.length,
    totalMs: Math.round(totalMs),
    minTransientGapMs: minGapMs === null ? null : Math.round(minGapMs),
  };
}

function main() {
  const args = process.argv.slice(2);
  const jsonOutput = args.includes("--json");
  const files = args.filter((a) => a !== "--json");

  if (files.length === 0) {
    console.error(
      "usage: node scripts/validate-ahap.js [--json] <file.ahap> [more files...]",
    );
    process.exit(2);
  }

  const { validateAhap, validateHapticEvents, ahapToHapticEvents } =
    loadAhapUtils();

  let anyErrors = false;
  const reports = [];

  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch (e) {
      anyErrors = true;
      reports.push({
        file,
        format: null,
        valid: false,
        issues: [
          {
            severity: "error",
            path: "$",
            message: `cannot read file: ${e.message}`,
          },
        ],
        summary: null,
      });
      continue;
    }

    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (e) {
      anyErrors = true;
      reports.push({
        file,
        format: null,
        valid: false,
        issues: [
          {
            severity: "error",
            path: "$",
            message: `not valid JSON: ${e.message}`,
          },
        ],
        summary: null,
      });
      continue;
    }

    let report;
    if (Array.isArray(parsed)) {
      const result = validateHapticEvents(parsed);
      report = {
        file,
        format: "HapticEvent[] (milliseconds)",
        valid: result.valid,
        issues: result.issues,
        summary: result.valid ? summarize(result.events) : null,
      };
    } else {
      const result = validateAhap(parsed);
      report = {
        file,
        format: "AHAP (seconds)",
        valid: result.valid,
        issues: result.issues,
        summary:
          result.valid && result.ahap
            ? summarize(ahapToHapticEvents(result.ahap))
            : null,
      };
    }
    if (!report.valid) anyErrors = true;
    reports.push(report);
  }

  if (jsonOutput) {
    console.log(JSON.stringify(reports, null, 2));
  } else {
    for (const report of reports) {
      const status = report.valid ? "OK   " : "FAIL ";
      console.log(
        `${status}${report.file}${report.format ? `  [${report.format}]` : ""}`,
      );
      for (const issue of report.issues) {
        const tag = issue.severity === "error" ? "  ERROR " : "  warn  ";
        console.log(`${tag}${issue.path}: ${issue.message}`);
      }
      if (report.summary) {
        const s = report.summary;
        const gap =
          s.minTransientGapMs === null ? "n/a" : `${s.minTransientGapMs}ms`;
        console.log(
          `       ${s.events} events (${s.transients} transient, ${s.continuous} continuous), ` +
            `length ${s.totalMs}ms, min transient gap ${gap}`,
        );
      }
    }
    const failed = reports.filter((r) => !r.valid).length;
    console.log(`\n${reports.length} file(s) checked, ${failed} with errors.`);
  }

  process.exit(anyErrors ? 1 : 0);
}

main();
