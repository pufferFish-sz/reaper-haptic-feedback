import React, { useState, useCallback, useEffect } from 'react';
import {
  Platform,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
  Pressable,
  useColorScheme,
} from 'react-native';
import TestBench from './src/TestBench';

import HapticFeedback, {
  HapticFeedbackTypes,
  TouchableHaptic,
  pattern,
  Patterns,
  playHaptic,
  useHaptics,
  getSystemHapticStatus,
} from 'react-native-haptic-feedback';
import type {
  HapticOptions,
  SystemHapticStatus,
} from 'react-native-haptic-feedback';

// ─── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_OPTIONS: HapticOptions = {
  enableVibrateFallback: true,
  ignoreAndroidSystemSettings: false,
};

type HapticEntry = { label: string; type: HapticFeedbackTypes };
type HapticGroup = { title: string; entries: HapticEntry[] };

const HAPTIC_GROUPS: HapticGroup[] = [
  {
    title: '冲击 Impact',
    entries: [
      { label: 'Light', type: HapticFeedbackTypes.impactLight },
      { label: 'Medium', type: HapticFeedbackTypes.impactMedium },
      { label: 'Heavy', type: HapticFeedbackTypes.impactHeavy },
      { label: 'Rigid', type: HapticFeedbackTypes.rigid },
      { label: 'Soft', type: HapticFeedbackTypes.soft },
    ],
  },
  {
    title: '通知 Notification',
    entries: [
      { label: 'Success', type: HapticFeedbackTypes.notificationSuccess },
      { label: 'Warning', type: HapticFeedbackTypes.notificationWarning },
      { label: 'Error', type: HapticFeedbackTypes.notificationError },
    ],
  },
  {
    title: '选择 Selection',
    entries: [{ label: 'Selection', type: HapticFeedbackTypes.selection }],
  },
  {
    title: '设备反馈',
    entries: [
      { label: 'Clock Tick', type: HapticFeedbackTypes.clockTick },
      { label: 'Context Click', type: HapticFeedbackTypes.contextClick },
      { label: 'Keyboard Press', type: HapticFeedbackTypes.keyboardPress },
      { label: 'Keyboard Release', type: HapticFeedbackTypes.keyboardRelease },
      { label: 'Keyboard Tap', type: HapticFeedbackTypes.keyboardTap },
      { label: 'Long Press', type: HapticFeedbackTypes.longPress },
      { label: 'Text Handle', type: HapticFeedbackTypes.textHandleMove },
      { label: 'Virtual Key', type: HapticFeedbackTypes.virtualKey },
      { label: 'Virtual Key ↑', type: HapticFeedbackTypes.virtualKeyRelease },
    ],
  },
  {
    title: 'Android 效果',
    entries: [
      { label: 'Click', type: HapticFeedbackTypes.effectClick },
      { label: 'Double Click', type: HapticFeedbackTypes.effectDoubleClick },
      { label: 'Heavy Click', type: HapticFeedbackTypes.effectHeavyClick },
      { label: 'Tick', type: HapticFeedbackTypes.effectTick },
    ],
  },
  {
    title: 'Android API 30+',
    entries: [
      { label: 'Confirm', type: HapticFeedbackTypes.confirm },
      { label: 'Reject', type: HapticFeedbackTypes.reject },
      { label: 'Gesture Start', type: HapticFeedbackTypes.gestureStart },
      { label: 'Gesture End', type: HapticFeedbackTypes.gestureEnd },
      { label: 'Segment Tick', type: HapticFeedbackTypes.segmentTick },
      {
        label: 'Seg. Freq. Tick',
        type: HapticFeedbackTypes.segmentFrequentTick,
      },
      { label: 'Toggle On', type: HapticFeedbackTypes.toggleOn },
      { label: 'Toggle Off', type: HapticFeedbackTypes.toggleOff },
    ],
  },
];

const AHAP_FILES = [
  {
    name: 'heartbeat',
    file: 'heartbeat.ahap',
    fallback: pattern('oO'),
    description: 'lub-dub double pulse',
  },
  {
    name: 'rumble',
    file: 'rumble.ahap',
    fallback: pattern('O=O'),
    description: 'continuous fade-out',
  },
  {
    name: 'celebration',
    file: 'celebration.ahap',
    fallback: pattern('o.o.o.O'),
    description: 'ascending burst',
  },
];

const PRESET_NOTATIONS: Record<string, string> = {
  success: 'oO.O',
  error: 'OO.OO',
  warning: 'O.O',
  heartbeat: 'oO--oO',
  tripleClick: 'o.o.o',
  notification: 'o-O=o',
};

const PATTERN_KEYS = [
  { char: 'o', display: 'o', hint: '轻' },
  { char: 'O', display: 'O', hint: '重' },
  { char: '.', display: '·', hint: '150ms' },
  { char: '-', display: '—', hint: '400ms' },
  { char: '=', display: '≡', hint: '1 s' },
];

// ─── Components ───────────────────────────────────────────────────────────────

function Badge({ label, color }: { label: string; color: string }) {
  return (
    <View
      style={[
        styles.badge,
        { backgroundColor: color + '22', borderColor: color },
      ]}
    >
      <Text style={[styles.badgeText, { color }]}>{label}</Text>
    </View>
  );
}

function SectionCard({
  title,
  children,
  cardBg,
  titleColor,
}: {
  title: string;
  children: React.ReactNode;
  cardBg: string;
  titleColor: string;
}) {
  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <Text style={[styles.cardTitle, { color: titleColor }]}>{title}</Text>
      {children}
    </View>
  );
}

function PatternPreview({
  notation,
  textColor,
}: {
  notation: string;
  textColor: string;
}) {
  return (
    <Text style={styles.patternLine}>
      {notation.split('').map((ch, i) => {
        let color = textColor;
        if (ch === 'o') color = '#60a5fa';
        else if (ch === 'O') color = '#818cf8';
        else if (['.', '-', '='].includes(ch)) color = '#f59e0b';
        return (
          <Text key={i} style={[styles.patternChar, { color }]}>
            {ch}
          </Text>
        );
      })}
    </Text>
  );
}

// ─── App ──────────────────────────────────────────────────────────────────────

export default function App(): React.JSX.Element {
  const isDark = useColorScheme() === 'dark';
  const bg = isDark ? '#0f172a' : '#f1f5f9';
  const cardBg = isDark ? '#1e293b' : '#ffffff';
  const textPrimary = isDark ? '#f8fafc' : '#0f172a';
  const textSecondary = isDark ? '#94a3b8' : '#64748b';
  const keyBg = isDark ? '#1e293b' : '#f8fafc';
  const keyBorder = isDark ? '#334155' : '#e2e8f0';

  const [tab, setTab] = useState<'demo' | 'bench'>('demo');
  const [status, setStatus] = useState<SystemHapticStatus | null>(null);
  const [hapticsEnabled, setHapticsEnabled] = useState(true);
  const [patternStr, setPatternStr] = useState('');
  const [lastPlayed, setLastPlayed] = useState('');

  // useHaptics hook demo — shared instance with default options
  const haptics = useHaptics(DEFAULT_OPTIONS);

  useEffect(() => {
    getSystemHapticStatus()
      .then(setStatus)
      .catch(() => {});
  }, []);

  const toggleEnabled = useCallback(() => {
    const next = !hapticsEnabled;
    HapticFeedback.setEnabled(next);
    setHapticsEnabled(next);
  }, [hapticsEnabled]);

  const appendKey = useCallback((char: string) => {
    HapticFeedback.trigger(HapticFeedbackTypes.clockTick, DEFAULT_OPTIONS);
    setPatternStr(prev => prev + char);
  }, []);

  const backspace = useCallback(() => {
    HapticFeedback.trigger(
      HapticFeedbackTypes.keyboardRelease,
      DEFAULT_OPTIONS,
    );
    setPatternStr(prev => prev.slice(0, -1));
  }, []);

  const clearPattern = useCallback(() => {
    setPatternStr('');
    setLastPlayed('');
  }, []);

  const playPattern = useCallback(() => {
    const events = pattern(patternStr);
    if (events.length === 0) return;
    setLastPlayed(patternStr);
    HapticFeedback.triggerPattern(events, DEFAULT_OPTIONS);
  }, [patternStr]);

  const playPreset = useCallback((name: string) => {
    const events = Patterns[name as keyof typeof Patterns];
    if (!events) return;
    setLastPlayed(`${name}  "${PRESET_NOTATIONS[name]}"`);
    HapticFeedback.triggerPattern(events, DEFAULT_OPTIONS);
  }, []);

  const patternEvents = patternStr ? pattern(patternStr) : [];
  const canPlay = patternStr.length > 0 && patternEvents.length > 0;

  return (
    <SafeAreaView style={[styles.safeArea, { backgroundColor: bg }]}>
      <StatusBar
        barStyle={isDark ? 'light-content' : 'dark-content'}
        backgroundColor={bg}
      />
      <View style={[styles.tabRow, { backgroundColor: cardBg }]}>
        {(
          [
            { key: 'demo', label: '库演示' },
            { key: 'bench', label: 'REAPER 调试台' },
          ] as const
        ).map(({ key, label }) => (
          <Pressable
            key={key}
            style={[styles.tabBtn, tab === key && styles.tabBtnActive]}
            onPress={() => setTab(key)}
          >
            <Text
              style={[
                styles.tabText,
                { color: tab === key ? '#ffffff' : textSecondary },
              ]}
            >
              {label}
            </Text>
          </Pressable>
        ))}
      </View>
      {tab === 'bench' && <TestBench />}
      {tab === 'demo' && (
        <ScrollView
          contentInsetAdjustmentBehavior="automatic"
          style={{ backgroundColor: bg }}
          contentContainerStyle={styles.scroll}
        >
          {/* Header */}
          <View style={[styles.card, { backgroundColor: cardBg }]}>
            <Text style={[styles.heading, { color: textPrimary }]}>
              触感反馈
            </Text>
            <Text style={[styles.subheading, { color: textSecondary }]}>
              react-native-haptic-feedback 演示
            </Text>

            {status ? (
              <View style={styles.badgeRow}>
                <Badge
                  label={
                    status.vibrationEnabled ? '✓ 震动已开启' : '✗ 震动已关闭'
                  }
                  color={status.vibrationEnabled ? '#22c55e' : '#ef4444'}
                />
                {status.ringerMode !== null && (
                  <Badge label={`响铃: ${status.ringerMode}`} color="#6366f1" />
                )}
                <Badge
                  label={
                    HapticFeedback.isSupported() ? '✓ 支持触感' : '✗ 不支持触感'
                  }
                  color={HapticFeedback.isSupported() ? '#22c55e' : '#f59e0b'}
                />
              </View>
            ) : (
              <Text style={[styles.hint, { color: textSecondary }]}>
                正在检查系统状态…
              </Text>
            )}
          </View>

          {/* Global enable/disable toggle */}
          <SectionCard
            title="全局开关"
            cardBg={cardBg}
            titleColor={textSecondary}
          >
            <Text
              style={[styles.hint, { color: textSecondary, marginBottom: 10 }]}
            >
              setEnabled() / isEnabled() — 库级总开关,可用于 app
              内震动偏好设置。
            </Text>
            <Pressable
              style={({ pressed }) => [
                styles.toggleBtn,
                { backgroundColor: hapticsEnabled ? '#22c55e' : '#ef4444' },
                pressed && styles.pressed,
              ]}
              onPress={toggleEnabled}
            >
              <Text style={styles.toggleBtnText}>
                震动: {hapticsEnabled ? '已启用' : '已禁用'}
              </Text>
            </Pressable>
          </SectionCard>

          {/* All haptic types */}
          {HAPTIC_GROUPS.map(group => (
            <SectionCard
              key={group.title}
              title={group.title}
              cardBg={cardBg}
              titleColor={textSecondary}
            >
              <View style={styles.chipWrap}>
                {group.entries.map(({ label, type }) => (
                  <TouchableHaptic
                    key={type}
                    hapticType={type}
                    hapticTrigger="onPress"
                    hapticOptions={DEFAULT_OPTIONS}
                    style={({ pressed }) => [
                      styles.chip,
                      pressed && styles.pressed,
                    ]}
                  >
                    <Text style={styles.chipText}>{label}</Text>
                  </TouchableHaptic>
                ))}
              </View>
            </SectionCard>
          ))}

          {/* useHaptics hook demo */}
          <SectionCard
            title="useHaptics Hook 演示"
            cardBg={cardBg}
            titleColor={textSecondary}
          >
            <Text
              style={[styles.hint, { color: textSecondary, marginBottom: 10 }]}
            >
              useHaptics() 共享实例,方法引用跨渲染稳定,自动合并默认选项。
            </Text>
            <View style={styles.chipWrap}>
              {(['impactLight', 'impactMedium', 'impactHeavy'] as const).map(
                type => (
                  <Pressable
                    key={type}
                    style={({ pressed }) => [
                      styles.chip,
                      styles.chipHook,
                      pressed && styles.pressed,
                    ]}
                    onPress={() => haptics.trigger(type)}
                  >
                    <Text style={styles.chipText}>{type}</Text>
                  </Pressable>
                ),
              )}
            </View>
          </SectionCard>

          {/* Pattern presets */}
          <SectionCard
            title="模式预设"
            cardBg={cardBg}
            titleColor={textSecondary}
          >
            <View style={styles.chipWrap}>
              {Object.keys(PRESET_NOTATIONS).map(name => (
                <Pressable
                  key={name}
                  style={({ pressed }) => [
                    styles.chip,
                    styles.chipPreset,
                    pressed && styles.pressed,
                  ]}
                  onPress={() => playPreset(name)}
                >
                  <Text style={styles.chipText}>{name}</Text>
                  <Text style={styles.chipSub}>{PRESET_NOTATIONS[name]}</Text>
                </Pressable>
              ))}
            </View>
          </SectionCard>

          {/* AHAP files */}
          <SectionCard
            title={`AHAP 文件  ·  ${
              Platform.OS === 'ios' ? 'iOS' : 'Android 回退'
            }`}
            cardBg={cardBg}
            titleColor={textSecondary}
          >
            <Text
              style={[styles.hint, { color: textSecondary, marginBottom: 10 }]}
            >
              {Platform.OS === 'ios'
                ? '播放打包在 app 内 haptics/ 目录里的 .ahap 文件。'
                : 'Android:以回退模式代替 .ahap 播放。'}
            </Text>
            <View style={styles.chipWrap}>
              {AHAP_FILES.map(({ name, file, fallback, description }) => (
                <Pressable
                  key={name}
                  style={({ pressed }) => [
                    styles.chip,
                    styles.chipAhap,
                    pressed && styles.pressed,
                  ]}
                  onPress={() => playHaptic(file, fallback, DEFAULT_OPTIONS)}
                >
                  <Text style={styles.chipText}>{name}</Text>
                  <Text style={styles.chipSub}>{description}</Text>
                </Pressable>
              ))}
            </View>
          </SectionCard>

          {/* Pattern playground */}
          <SectionCard
            title="模式试验场"
            cardBg={cardBg}
            titleColor={textSecondary}
          >
            <View
              style={[
                styles.patternDisplay,
                { borderColor: canPlay ? '#3b82f6' : keyBorder },
              ]}
            >
              {patternStr ? (
                <PatternPreview notation={patternStr} textColor={textPrimary} />
              ) : (
                <Text
                  style={[styles.patternPlaceholder, { color: textSecondary }]}
                >
                  点下方按键编一段节奏…
                </Text>
              )}
              {patternStr.length > 0 && (
                <Text style={[styles.eventCount, { color: textSecondary }]}>
                  {patternEvents.length} 个事件
                </Text>
              )}
            </View>

            <View style={[styles.legendRow, { borderColor: keyBorder }]}>
              {PATTERN_KEYS.map(k => (
                <View key={k.char} style={styles.legendCell}>
                  <Text style={[styles.legendChar, { color: textPrimary }]}>
                    {k.char}
                  </Text>
                  <Text style={[styles.legendHint, { color: textSecondary }]}>
                    {k.hint}
                  </Text>
                </View>
              ))}
            </View>

            <View style={styles.keyboard}>
              <View style={styles.keyRow}>
                {PATTERN_KEYS.map(k => (
                  <Pressable
                    key={k.char}
                    style={({ pressed }) => [
                      styles.key,
                      { backgroundColor: keyBg, borderColor: keyBorder },
                      pressed && styles.keyDown,
                    ]}
                    onPress={() => appendKey(k.char)}
                  >
                    <Text style={[styles.keyMain, { color: textPrimary }]}>
                      {k.display}
                    </Text>
                    <Text style={[styles.keySub, { color: textSecondary }]}>
                      {k.hint}
                    </Text>
                  </Pressable>
                ))}
              </View>
              <View style={styles.keyRow}>
                <Pressable
                  style={({ pressed }) => [
                    styles.keyAction,
                    { backgroundColor: keyBg, borderColor: keyBorder },
                    pressed && styles.keyDown,
                  ]}
                  onPress={backspace}
                >
                  <Text style={[styles.keyMain, { color: textPrimary }]}>
                    ⌫
                  </Text>
                </Pressable>
                <Pressable
                  style={({ pressed }) => [
                    styles.keyAction,
                    { borderColor: '#fca5a5', borderWidth: 1 },
                    pressed && styles.keyDown,
                  ]}
                  onPress={clearPattern}
                >
                  <Text style={[styles.keyMain, { color: '#ef4444' }]}>
                    清空
                  </Text>
                </Pressable>
              </View>
            </View>

            <Pressable
              style={({ pressed }) => [
                styles.playBtn,
                !canPlay && styles.playBtnDisabled,
                pressed && canPlay && styles.pressed,
              ]}
              onPress={playPattern}
              disabled={!canPlay}
            >
              <Text
                style={[
                  styles.playBtnText,
                  !canPlay && styles.playBtnTextDisabled,
                ]}
              >
                ▶ 播放
              </Text>
            </Pressable>

            {lastPlayed ? (
              <Text style={[styles.lastPlayed, { color: textSecondary }]}>
                上次: {lastPlayed}
              </Text>
            ) : null}
          </SectionCard>
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  safeArea: { flex: 1 },
  scroll: { padding: 16, gap: 12 },

  tabRow: {
    flexDirection: 'row',
    marginHorizontal: 16,
    marginTop: 8,
    borderRadius: 10,
    padding: 4,
    gap: 4,
  },
  tabBtn: {
    flex: 1,
    borderRadius: 8,
    paddingVertical: 8,
    alignItems: 'center',
  },
  tabBtnActive: { backgroundColor: '#3b82f6' },
  tabText: { fontSize: 13, fontWeight: '700' },

  card: {
    borderRadius: 14,
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.07,
    shadowRadius: 4,
    elevation: 2,
  },
  heading: { fontSize: 26, fontWeight: '700', marginBottom: 4 },
  subheading: { fontSize: 13, marginBottom: 12 },
  cardTitle: {
    fontSize: 11,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: 12,
  },

  badgeRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  badge: {
    borderRadius: 20,
    borderWidth: 1,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  badgeText: { fontSize: 12, fontWeight: '600' },
  hint: { fontSize: 13 },

  toggleBtn: { borderRadius: 10, paddingVertical: 12, alignItems: 'center' },
  toggleBtnText: { color: '#fff', fontWeight: '700', fontSize: 15 },

  chipWrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: {
    borderRadius: 20,
    paddingHorizontal: 14,
    paddingVertical: 8,
    backgroundColor: '#3b82f6',
    alignItems: 'center',
  },
  chipHook: { backgroundColor: '#0ea5e9' },
  chipPreset: { backgroundColor: '#8b5cf6' },
  chipAhap: { backgroundColor: '#f97316' },
  pressed: { opacity: 0.65 },
  chipText: { color: '#fff', fontSize: 13, fontWeight: '600' },
  chipSub: {
    color: 'rgba(255,255,255,0.75)',
    fontSize: 10,
    fontFamily: 'monospace',
    marginTop: 1,
  },

  patternDisplay: {
    borderWidth: 1.5,
    borderRadius: 10,
    minHeight: 60,
    padding: 12,
    justifyContent: 'center',
    marginBottom: 12,
  },
  patternLine: { flexDirection: 'row', flexWrap: 'wrap' },
  patternChar: {
    fontSize: 26,
    fontFamily: 'monospace',
    fontWeight: '700',
    letterSpacing: 3,
  },
  patternPlaceholder: { fontSize: 14, fontStyle: 'italic' },
  eventCount: { fontSize: 11, marginTop: 6 },

  legendRow: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    borderWidth: 1,
    borderRadius: 8,
    paddingVertical: 8,
    marginBottom: 12,
  },
  legendCell: { alignItems: 'center', gap: 3 },
  legendChar: { fontSize: 16, fontWeight: '700', fontFamily: 'monospace' },
  legendHint: { fontSize: 10 },

  keyboard: { gap: 8 },
  keyRow: { flexDirection: 'row', gap: 8 },
  key: {
    flex: 1,
    borderRadius: 10,
    borderWidth: 1,
    paddingVertical: 10,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 3,
    minHeight: 58,
  },
  keyAction: {
    flex: 1,
    borderRadius: 10,
    borderWidth: 1,
    paddingVertical: 14,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 52,
  },
  keyDown: { opacity: 0.55, transform: [{ scale: 0.97 }] },
  keyMain: { fontSize: 20, fontWeight: '600' },
  keySub: { fontSize: 10 },

  playBtn: {
    marginTop: 12,
    backgroundColor: '#22c55e',
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
  },
  playBtnDisabled: { backgroundColor: '#d1d5db' },
  playBtnText: { color: '#fff', fontWeight: '700', fontSize: 16 },
  playBtnTextDisabled: { color: '#9ca3af' },
  lastPlayed: {
    marginTop: 10,
    fontSize: 12,
    textAlign: 'center',
    fontStyle: 'italic',
  },
});
