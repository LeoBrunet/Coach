import * as z from "zod";

// Shared data model between the iOS app (API) and Claude (MCP tools).
// Keep in sync with ios/Coach/Models/Models.swift.

export const Sport = z.enum(["course", "velo", "natation", "muscu", "repos"]);
export type Sport = z.infer<typeof Sport>;

export const Zone = z.number().int().min(1).max(5);

const Target = z
  .object({
    paceSecPerKm: z.number().int().positive().optional().describe("Running pace in seconds per km (e.g. 245 = 4:05/km)"),
    swimPaceSecPer100m: z.number().int().positive().optional().describe("Swim pace in seconds per 100 m"),
    speedKmh: z.number().positive().optional(),
    hrMin: z.number().int().positive().optional(),
    hrMax: z.number().int().positive().optional(),
  })
  .strict();

export const Step = z
  .object({
    name: z.string().describe("Short label, e.g. 'Échauffement', '6 × 800 m'"),
    detail: z.string().optional().describe("One line of instructions"),
    kind: z.enum(["warmup", "work", "recovery", "cooldown", "set"]).default("work"),
    zone: Zone.describe("Intensity zone 1–5"),
    durationMin: z.number().positive().optional(),
    durationSec: z.number().int().positive().optional().describe("Use for short steps (e.g. 20 s strides) instead of fractional minutes"),
    distanceM: z.number().positive().optional(),
    repeat: z.number().int().min(1).optional().describe("Number of repetitions of this step (with `recovery` between)"),
    recovery: z
      .object({ durationMin: z.number().positive().optional(), durationSec: z.number().int().positive().optional(), distanceM: z.number().positive().optional(), zone: Zone.default(1) })
      .optional(),
    target: Target.optional(),
  })
  .strict();
export type Step = z.infer<typeof Step>;

export const Cue = z.object({ title: z.string(), detail: z.string().optional() }).strict();

export const SessionInput = z
  .object({
    id: z.string().optional().describe("Omit to create; pass an existing id to update"),
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("YYYY-MM-DD"),
    sport: Sport,
    title: z.string(),
    subtitle: z.string().optional(),
    durationMin: z.number().int().nonnegative(),
    load: z.enum(["Faible", "Modérée", "Élevée"]).default("Modérée"),
    why: z.string().optional().describe("Why this session, in 1–2 sentences"),
    target: Target.extend({ distanceKm: z.number().positive().optional() }).optional(),
    cues: z.array(Cue).max(5).default([]).describe("Things to remember during the session"),
    steps: z.array(Step).default([]),
  })
  .strict();
export type SessionInput = z.infer<typeof SessionInput>;

export const Profile = z
  .object({
    name: z.string().optional(),
    tagline: z.string().optional(),
    goal: z
      .object({ title: z.string(), date: z.string().optional(), targetTime: z.string().optional() })
      .optional(),
    availability: z.string().optional(),
    injuries: z.string().optional(),
    sports: z.array(Sport).optional(),
    maxHr: z.number().int().positive().optional(),
    timezone: z.string().optional().describe("IANA time zone, set by the app"),
    language: z.string().optional().describe("App language ('fr', 'en'…), set by the app"),
    restingHr: z.number().int().positive().optional(),
    notes: z.string().optional(),
  })
  .strict();
export type Profile = z.infer<typeof Profile>;

export const WorkoutUpload = z.object({
  id: z.string(),
  sport: Sport,
  start: z.string(),
  end: z.string(),
  localDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("Day of the workout in the athlete's time zone"),
  durationS: z.number(),
  distanceM: z.number().nullable().optional(),
  energyKcal: z.number().nullable().optional(),
  avgHr: z.number().nullable().optional(),
  maxHr: z.number().nullable().optional(),
  elevationM: z.number().nullable().optional(),
  details: z
    .object({
      laps: z.array(z.object({ index: z.number(), durationS: z.number(), distanceM: z.number().nullable() })).optional(),
      zonesMin: z.array(z.number()).length(5).optional(),
      route: z.array(z.tuple([z.number(), z.number(), z.number().nullable()])).optional(),
    })
    .partial()
    .default({}),
});
export type WorkoutUpload = z.infer<typeof WorkoutUpload>;

export const DailyMetrics = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  sleepMin: z.number().nullable().optional(),
  hrvMs: z.number().nullable().optional(),
  restingHr: z.number().nullable().optional(),
  vo2max: z.number().nullable().optional(),
});
export type DailyMetrics = z.infer<typeof DailyMetrics>;

export const KeyPoint = z.object({ kind: z.enum(["good", "warning", "next"]), text: z.string() }).strict();
