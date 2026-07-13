import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  useColorScheme,
} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';

import HapticFeedback, {
  ahapToHapticEvents,
  validateAhap,
  validateHapticEvents,
} from 'react-native-haptic-feedback';
import type {
  AhapIssue,
  HapticEvent,
  HapticOptions,
} from 'react-native-haptic-feedback';

/**
 * REAPER haptics test bench.
 *
 * Fast iteration path for REAPER-authored patterns, no rebuild required:
 * serve your export folder over HTTP on the authoring machine
 * (`python -m http.server 8765`), point the URL field at a file, and turn
 * on Watch — every time REAPER re-exports, the phone re-validates and
 * replays it automatically.
 *
 * Accepts both formats, auto-detected:
 * - `.ahap` (JSON object with a `Pattern` array, times in SECONDS)
 * - `HapticEvent[]` (JSON array, times in MILLISECONDS)
 *
 * PREVIEW PATH, deliberately lossy: AHAP input is converted to
 * `HapticEvent[]` and played through `triggerPattern`. Static
 * transient/continuous events with intensity+sharpness reproduce exactly;
 * parameter curves, audio events and envelope parameters are dropped (the
 * report lists every drop). For bit-exact Core Haptics playback, bundle the
 * file and use `playAHAP` from the demo tab.
 */

const PLAY_OPTIONS: HapticOptions = {
  enableVibrateFallback: true,
  ignoreAndroidSystemSettings: false,
};

const URL_STORAGE_KEY = '@testbench/url';
const WATCH_INTERVAL_MS = 1000;

type BenchReport = {
  source: string;
  format: 'AHAP (seconds) → preview conversion' | 'HapticEvent[] (ms)' | null;
  issues: AhapIssue[];
  valid: boolean;
  events: HapticEvent[];
  playedAt: string | null;
};

function analyze(text: string, source: string): BenchReport {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    return {
      source,
      format: null,
      valid: false,
      events: [],
      playedAt: null,
      issues: [
        {
          severity: 'error',
          path: '$',
          message: `not valid JSON: ${(e as Error).message}`,
        },
      ],
    };
  }

  if (Array.isArray(parsed)) {
    const result = validateHapticEvents(parsed);
    return {
      source,
      format: 'HapticEvent[] (ms)',
      valid: result.valid,
      issues: result.issues,
      events: result.events ?? [],
      playedAt: null,
    };
  }

  const result = validateAhap(parsed);
  return {
    source,
    format: 'AHAP (seconds) → preview conversion',
    valid: result.valid,
    issues: result.issues,
    events: result.valid && result.ahap ? ahapToHapticEvents(result.ahap) : [],
    playedAt: null,
  };
}

function patternLengthMs(events: HapticEvent[]): number {
  return events.reduce(
    (max, e) => Math.max(max, e.time + (e.duration ?? 0)),
    0,
  );
}

// ─── Timeline ─────────────────────────────────────────────────────────────────

function Timeline({
  events,
  border,
}: {
  events: HapticEvent[];
  border: string;
}) {
  const totalMs = Math.max(patternLengthMs(events), 1) * 1.05;
  return (
    <View style={[styles.timeline, { borderColor: border }]}>
      {events.map((e, i) => {
        const isContinuous = e.type === 'continuous';
        const leftPct = (e.time / totalMs) * 100;
        const widthPct = isContinuous
          ? Math.max((((e.duration ?? 100) as number) / totalMs) * 100, 1)
          : 0;
        const intensity = e.intensity ?? 0.5;
        const sharpness = e.sharpness ?? 0.5;
        return (
          <View
            key={i}
            style={[
              styles.timelineEvent,
              {
                left: `${leftPct}%`,
                height: `${Math.max(intensity * 100, 8)}%`,
                opacity: 0.45 + 0.55 * sharpness,
                backgroundColor: isContinuous ? '#f97316' : '#3b82f6',
              },
              isContinuous ? { width: `${widthPct}%` } : styles.timelineTick,
            ]}
          />
        );
      })}
    </View>
  );
}

// ─── Test bench ───────────────────────────────────────────────────────────────

export default function TestBench(): React.JSX.Element {
  const isDark = useColorScheme() === 'dark';
  const bg = isDark ? '#0f172a' : '#f1f5f9';
  const cardBg = isDark ? '#1e293b' : '#ffffff';
  const textPrimary = isDark ? '#f8fafc' : '#0f172a';
  const textSecondary = isDark ? '#94a3b8' : '#64748b';
  const inputBg = isDark ? '#0f172a' : '#f8fafc';
  const inputBorder = isDark ? '#334155' : '#e2e8f0';

  const [url, setUrl] = useState('');
  const [watching, setWatching] = useState(false);
  const [fetchStatus, setFetchStatus] = useState('');
  const [pasted, setPasted] = useState('');
  const [report, setReport] = useState<BenchReport | null>(null);

  // Last text seen by the watcher; watch mode only replays when it changes.
  const lastTextRef = useRef<string | null>(null);
  const urlRef = useRef(url);
  urlRef.current = url;

  useEffect(() => {
    AsyncStorage.getItem(URL_STORAGE_KEY)
      .then(saved => {
        if (saved) setUrl(saved);
      })
      .catch(() => {});
  }, []);

  const play = useCallback((events: HapticEvent[]) => {
    HapticFeedback.triggerPattern(events, PLAY_OPTIONS);
  }, []);

  const runText = useCallback(
    (text: string, source: string, autoPlay: boolean) => {
      const next = analyze(text, source);
      if (autoPlay && next.valid && next.events.length > 0) {
        HapticFeedback.triggerPattern(next.events, PLAY_OPTIONS);
        next.playedAt = new Date().toLocaleTimeString();
      }
      setReport(next);
      return next;
    },
    [],
  );

  const fetchAndRun = useCallback(
    async (silent: boolean) => {
      const target = urlRef.current.trim();
      if (!target) {
        if (!silent) setFetchStatus('enter a URL first');
        return;
      }
      AsyncStorage.setItem(URL_STORAGE_KEY, target).catch(() => {});
      try {
        // Cache-buster: http.server and RN's URL cache both love stale files.
        const sep = target.includes('?') ? '&' : '?';
        const res = await fetch(`${target}${sep}_=${Date.now()}`);
        if (!res.ok) {
          setFetchStatus(`HTTP ${res.status} from ${target}`);
          return;
        }
        const text = await res.text();
        const changed = text !== lastTextRef.current;
        lastTextRef.current = text;
        if (!silent || changed) {
          const result = runText(text, target.split('/').pop() ?? target, true);
          setFetchStatus(
            `${new Date().toLocaleTimeString()} — ${
              changed ? 'file changed, ' : ''
            }${result.valid ? 'played' : 'NOT played (errors)'}`,
          );
        }
      } catch (e) {
        setFetchStatus(`fetch failed: ${(e as Error).message}`);
      }
    },
    [runText],
  );

  useEffect(() => {
    if (!watching) return;
    lastTextRef.current = null; // force a play on the first poll
    const id = setInterval(() => {
      fetchAndRun(true);
    }, WATCH_INTERVAL_MS);
    return () => clearInterval(id);
  }, [watching, fetchAndRun]);

  const summary =
    report && report.events.length > 0
      ? `${report.events.length} events · ` +
        `${report.events.filter(e => e.type !== 'continuous').length} transient · ` +
        `${report.events.filter(e => e.type === 'continuous').length} continuous · ` +
        `${Math.round(patternLengthMs(report.events))} ms`
      : null;

  return (
    <ScrollView
      contentInsetAdjustmentBehavior="automatic"
      style={{ backgroundColor: bg }}
      contentContainerStyle={styles.scroll}
      keyboardShouldPersistTaps="handled"
    >
      {/* Live URL */}
      <View style={[styles.card, { backgroundColor: cardBg }]}>
        <Text style={[styles.cardTitle, { color: textSecondary }]}>
          Live URL · no-rebuild reload
        </Text>
        <Text style={[styles.hint, { color: textSecondary }]}>
          Serve your REAPER export folder on the authoring machine:{' '}
          <Text style={styles.mono}>python -m http.server 8765</Text>, then use{' '}
          <Text style={styles.mono}>http://&lt;pc-ip&gt;:8765/file.ahap</Text>.
          Watch polls every second and replays whenever the file changes.
        </Text>
        <TextInput
          style={[
            styles.input,
            {
              backgroundColor: inputBg,
              borderColor: inputBorder,
              color: textPrimary,
            },
          ]}
          value={url}
          onChangeText={setUrl}
          placeholder="http://192.168.1.10:8765/my-effect.ahap"
          placeholderTextColor={textSecondary}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
        />
        <View style={styles.btnRow}>
          <Pressable
            style={({ pressed }) => [
              styles.btn,
              styles.btnPrimary,
              pressed && styles.pressed,
            ]}
            onPress={() => fetchAndRun(false)}
          >
            <Text style={styles.btnText}>Fetch & Play</Text>
          </Pressable>
          <Pressable
            style={({ pressed }) => [
              styles.btn,
              watching ? styles.btnWatchOn : styles.btnWatchOff,
              pressed && styles.pressed,
            ]}
            onPress={() => setWatching(w => !w)}
          >
            <Text style={styles.btnText}>
              {watching ? 'Watching…' : 'Watch: off'}
            </Text>
          </Pressable>
        </View>
        {fetchStatus ? (
          <Text style={[styles.status, { color: textSecondary }]}>
            {fetchStatus}
          </Text>
        ) : null}
      </View>

      {/* Paste JSON */}
      <View style={[styles.card, { backgroundColor: cardBg }]}>
        <Text style={[styles.cardTitle, { color: textSecondary }]}>
          Paste JSON · AHAP or HapticEvent[]
        </Text>
        <Text style={[styles.hint, { color: textSecondary }]}>
          Auto-detected: object with Pattern = AHAP (seconds), array ={' '}
          HapticEvent[] (milliseconds).
        </Text>
        <TextInput
          style={[
            styles.input,
            styles.pasteInput,
            {
              backgroundColor: inputBg,
              borderColor: inputBorder,
              color: textPrimary,
            },
          ]}
          value={pasted}
          onChangeText={setPasted}
          placeholder='{"Version":1.0,"Pattern":[...]}'
          placeholderTextColor={textSecondary}
          multiline
          autoCapitalize="none"
          autoCorrect={false}
        />
        <View style={styles.btnRow}>
          <Pressable
            style={({ pressed }) => [
              styles.btn,
              styles.btnNeutral,
              pressed && styles.pressed,
            ]}
            onPress={() => runText(pasted, 'pasted JSON', false)}
          >
            <Text style={styles.btnText}>Validate</Text>
          </Pressable>
          <Pressable
            style={({ pressed }) => [
              styles.btn,
              styles.btnPrimary,
              pressed && styles.pressed,
            ]}
            onPress={() => runText(pasted, 'pasted JSON', true)}
          >
            <Text style={styles.btnText}>Validate & Play</Text>
          </Pressable>
          <Pressable
            style={({ pressed }) => [
              styles.btn,
              styles.btnDanger,
              pressed && styles.pressed,
            ]}
            onPress={() => setPasted('')}
          >
            <Text style={styles.btnText}>Clear</Text>
          </Pressable>
        </View>
      </View>

      {/* Report */}
      {report && (
        <View style={[styles.card, { backgroundColor: cardBg }]}>
          <Text style={[styles.cardTitle, { color: textSecondary }]}>
            Report · {report.source}
          </Text>
          <View style={styles.badgeRow}>
            <Text
              style={[
                styles.resultBadge,
                report.valid ? styles.badgeOk : styles.badgeFail,
              ]}
            >
              {report.valid ? 'VALID' : 'INVALID'}
            </Text>
            {report.format && (
              <Text
                style={[
                  styles.formatBadge,
                  { color: textSecondary, borderColor: inputBorder },
                ]}
              >
                {report.format}
              </Text>
            )}
          </View>

          {summary && (
            <Text style={[styles.summary, { color: textPrimary }]}>
              {summary}
            </Text>
          )}
          {report.events.length > 0 && (
            <Timeline events={report.events} border={inputBorder} />
          )}

          {report.issues.length > 0 ? (
            report.issues.map((issue, i) => (
              <View key={i} style={styles.issueRow}>
                <Text
                  style={[
                    styles.issueTag,
                    issue.severity === 'error'
                      ? styles.issueError
                      : styles.issueWarn,
                  ]}
                >
                  {issue.severity === 'error' ? 'ERR' : 'WARN'}
                </Text>
                <View style={styles.issueBody}>
                  <Text style={[styles.issuePath, { color: textSecondary }]}>
                    {issue.path}
                  </Text>
                  <Text style={[styles.issueMsg, { color: textPrimary }]}>
                    {issue.message}
                  </Text>
                </View>
              </View>
            ))
          ) : (
            <Text style={[styles.hint, { color: textSecondary }]}>
              No issues found.
            </Text>
          )}

          <View style={styles.btnRow}>
            <Pressable
              style={({ pressed }) => [
                styles.btn,
                report.events.length > 0
                  ? styles.btnPrimary
                  : styles.btnDisabled,
                pressed && styles.pressed,
              ]}
              disabled={report.events.length === 0}
              onPress={() => play(report.events)}
            >
              <Text style={styles.btnText}>Replay</Text>
            </Pressable>
            <Pressable
              style={({ pressed }) => [
                styles.btn,
                styles.btnDanger,
                pressed && styles.pressed,
              ]}
              onPress={() => HapticFeedback.stop()}
            >
              <Text style={styles.btnText}>Stop</Text>
            </Pressable>
          </View>
          {report.playedAt && (
            <Text style={[styles.status, { color: textSecondary }]}>
              played at {report.playedAt}
            </Text>
          )}
        </View>
      )}

      {/* Fidelity note */}
      <View style={[styles.card, { backgroundColor: cardBg }]}>
        <Text style={[styles.cardTitle, { color: textSecondary }]}>
          Preview fidelity
        </Text>
        <Text style={[styles.hint, { color: textSecondary }]}>
          This tab plays AHAP through a lossy PREVIEW path (AHAP → HapticEvent[]
          → triggerPattern). Static transient/continuous events with intensity +
          sharpness reproduce 1:1 — parameter curves, audio events and envelope
          parameters are dropped (see warnings above). For bit-exact Core
          Haptics playback, bundle the file and use the AHAP Files section of
          the demo tab. Timeline: blue ticks = transients, orange blocks =
          continuous; bar height = intensity, opacity = sharpness.
        </Text>
      </View>
    </ScrollView>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  scroll: { padding: 16, gap: 12 },
  card: {
    borderRadius: 14,
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.07,
    shadowRadius: 4,
    elevation: 2,
  },
  cardTitle: {
    fontSize: 11,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 10,
  },
  hint: { fontSize: 13, lineHeight: 18, marginBottom: 10 },
  mono: { fontFamily: 'monospace', fontSize: 12 },

  input: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 13,
    fontFamily: 'monospace',
    marginBottom: 10,
  },
  pasteInput: { minHeight: 120, textAlignVertical: 'top' },

  btnRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  btn: {
    borderRadius: 10,
    paddingHorizontal: 16,
    paddingVertical: 10,
    alignItems: 'center',
  },
  btnPrimary: { backgroundColor: '#3b82f6' },
  btnNeutral: { backgroundColor: '#64748b' },
  btnDanger: { backgroundColor: '#ef4444' },
  btnWatchOn: { backgroundColor: '#22c55e' },
  btnWatchOff: { backgroundColor: '#64748b' },
  btnDisabled: { backgroundColor: '#d1d5db' },
  btnText: { color: '#fff', fontWeight: '700', fontSize: 13 },
  pressed: { opacity: 0.65 },

  status: { fontSize: 12, marginTop: 8, fontStyle: 'italic' },

  badgeRow: {
    flexDirection: 'row',
    gap: 8,
    alignItems: 'center',
    marginBottom: 8,
  },
  resultBadge: {
    fontSize: 12,
    fontWeight: '800',
    color: '#fff',
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    overflow: 'hidden',
  },
  badgeOk: { backgroundColor: '#22c55e' },
  badgeFail: { backgroundColor: '#ef4444' },
  formatBadge: {
    fontSize: 11,
    borderWidth: 1,
    borderRadius: 6,
    paddingHorizontal: 6,
    paddingVertical: 2,
  },

  summary: { fontSize: 13, fontWeight: '600', marginBottom: 8 },

  timeline: {
    height: 64,
    borderWidth: 1,
    borderRadius: 8,
    marginBottom: 12,
    overflow: 'hidden',
  },
  timelineEvent: { position: 'absolute', bottom: 0, borderRadius: 1 },
  timelineTick: { width: 3 },

  issueRow: { flexDirection: 'row', gap: 8, marginBottom: 8 },
  issueTag: {
    fontSize: 10,
    fontWeight: '800',
    color: '#fff',
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
    overflow: 'hidden',
    alignSelf: 'flex-start',
    minWidth: 38,
    textAlign: 'center',
  },
  issueError: { backgroundColor: '#ef4444' },
  issueWarn: { backgroundColor: '#f59e0b' },
  issueBody: { flex: 1 },
  issuePath: { fontSize: 11, fontFamily: 'monospace' },
  issueMsg: { fontSize: 12, lineHeight: 16 },
});
