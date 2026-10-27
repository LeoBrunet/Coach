import type { Store } from "./store.js";
import { addDays, isoDate } from "./store.js";

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const sd = (xs: number[]) => {
  const m = mean(xs);
  if (m == null || xs.length < 2) return null;
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
};
const r1 = (x: number | null) => (x == null ? null : Math.round(x * 10) / 10);
const r2 = (x: number | null) => (x == null ? null : Math.round(x * 100) / 100);

/** Edwards TRIMP from minutes per HR zone; else duration × intensity estimated from avg/max HR; else RPE × minutes / 2. */
function workoutLoad(w: { durationS: number; avgHr?: number | null; rpe: number | null; details?: any }, maxHr: number) {
  const zones: number[] | undefined = w.details?.zonesMin;
  if (zones?.length) return zones.reduce((a, min, i) => a + min * (i + 1), 0);
  const minutes = w.durationS / 60;
  if (w.avgHr) {
    const pct = w.avgHr / maxHr;
    const zone = pct < 0.6 ? 1 : pct < 0.7 ? 2 : pct < 0.8 ? 3 : pct < 0.9 ? 4 : 5;
    return minutes * zone;
  }
  if (w.rpe) return (minutes * w.rpe) / 2;
  return minutes * 2;
}

/** Morning readiness indicators: 7-day HRV / resting HR vs 60-day baseline, sleep, acute:chronic load ratio. */
export async function computeReadiness(store: Store, userId: string, tz: string, maxHrProfile?: number) {
  const today = isoDate(new Date(), tz);
  const day = (n: number) => isoDate(addDays(new Date(), -n), tz);
  const metrics = await store.dailyMetrics(userId, 67, tz);
  const recent = metrics.filter((m) => m.date > day(7));
  const baseline = metrics.filter((m) => m.date <= day(7));
  const pick = (rows: typeof metrics, key: "hrvMs" | "restingHr" | "sleepMin") =>
    rows.map((m) => m[key]).filter((v): v is number => typeof v === "number");

  const trend = (key: "hrvMs" | "restingHr") => {
    const r = mean(pick(recent, key)), b = mean(pick(baseline, key)), s = sd(pick(baseline, key));
    return {
      avg7d: r1(r),
      baseline60d: r1(b),
      deltaPct: r != null && b ? r1(((r - b) / b) * 100) : null,
      // Normal range = baseline ± 0.5 SD (HRV4Training-style).
      normalRange: b != null && s != null ? [r1(b - 0.5 * s), r1(b + 0.5 * s)] : null,
      daysOfData: { recent: pick(recent, key).length, baseline: pick(baseline, key).length },
    };
  };

  const lastNight = metrics.find((m) => m.date === today)?.sleepMin ?? null;
  const workouts = await store.listWorkouts(userId, { from: day(28) });
  const maxHr = maxHrProfile ?? Math.max(185, ...workouts.map((w) => w.maxHr ?? 0));
  const loadSince = (days: number) =>
    workouts.filter((w) => w.localDate > day(days)).reduce((a, w) => a + workoutLoad(w as any, maxHr), 0);
  const acute = loadSince(7);
  const chronicWeekly = loadSince(28) / 4;
  const acwr = chronicWeekly > 0 ? acute / chronicWeekly : null;

  return {
    date: today,
    dataFresh: lastNight != null,
    note: lastNight == null ? "Le sommeil de la nuit dernière n'est pas encore synchronisé (l'app iPhone doit s'ouvrir ou synchroniser)." : undefined,
    sleep: { lastNightMin: lastNight, avg7dMin: r1(mean(pick(recent, "sleepMin"))) },
    hrv: trend("hrvMs"),
    restingHr: trend("restingHr"),
    load: {
      method: "TRIMP d'Edwards (minutes × zone FC 1–5), somme 7 j vs moyenne hebdo 28 j",
      acute7d: Math.round(acute),
      chronicWeeklyAvg28d: Math.round(chronicWeekly),
      acwr: r2(acwr),
      acwrZone: acwr == null ? null : acwr < 0.8 ? "sous-charge" : acwr <= 1.3 ? "zone optimale" : acwr <= 1.5 ? "vigilance" : "risque élevé",
    },
  };
}
