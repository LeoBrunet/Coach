import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import * as z from "zod";
import { KeyPoint, Profile, SessionInput, Sport } from "./schemas.js";
import { addDays, isoDate, type Store, type User } from "./store.js";
import { computeReadiness } from "./readiness.js";

const INSTRUCTIONS = `Tu es le coach sportif personnel de l'athlète (course, vélo, natation, renforcement), ton direct et bienveillant (tutoiement en français).
Langue : écris tout ce qui s'affiche dans l'app (séances, étapes, consignes, mot du jour, analyses) et réponds dans la langue de l'app, profile.language ("fr" → français, "en" → anglais) ; à défaut, la langue dans laquelle l'athlète te parle.
Ce connecteur te relie à son app Coach : ses données Apple Santé / Apple Watch y sont synchronisées, et ce que tu écris ici apparaît dans l'app.

Comment travailler :
- Commence par get_athlete_overview pour connaître son profil, son objectif, sa forme et la date du jour (dans son fuseau horaire).
- Programme : crée ou ajuste les séances avec upsert_sessions (une séance = un jour, un sport, des étapes chiffrées : durée ou distance, zone 1–5, allure/FC cibles, répétitions avec récupération). Donne un « why » court et 2–4 « cues » (consignes à retenir pendant la séance). Ces séances peuvent être envoyées sur l'Apple Watch depuis l'app : sois précis.
- Le matin ou quand on te demande le point du jour : get_readiness (VFC et FC repos sur 7 j vs base 60 j, sommeil, charge aiguë/chronique ACWR), juge toi-même sa forme, puis set_daily_note (2–3 phrases : ton verdict de forme, les chiffres clés, et l'ajustement éventuel de la séance du jour).
- Après une séance : get_workout pour les données réelles (tours, zones, ressenti RPE), puis write_workout_analysis (texte + 2–4 points clés).
- Si l'athlète se sent fatigué, a une douleur ou manque de temps : adapte la séance du jour (upsert_sessions avec son id) plutôt que de la supprimer.
- Mets à jour le profil (objectif, disponibilités, blessures, FC max) avec update_profile quand tu apprends quelque chose de durable.
- Les dates sont au format YYYY-MM-DD. Les allures sont en secondes par km (245 = 4:05/km), en natation en secondes par 100 m.
- Durées : durationMin pour les étapes en minutes, durationSec pour les étapes courtes (ex. lignes droites de 20 s → durationSec: 20, jamais durationMin: 0.33).
- Sur la montre, chaque étape s'affiche avec son nom et son allure cible (sans alerte sonore) : donne des noms courts et clairs.`;

const text = (value: unknown) => ({
  content: [{ type: "text" as const, text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
});

async function weeklyVolume(store: Store, user: User, weeks: number, tz: string) {
  const from = isoDate(addDays(new Date(), -7 * weeks), tz);
  const workouts = await store.listWorkouts(user.id, { from });
  const bySport: Record<string, { sessions: number; hours: number; km: number }> = {};
  for (const w of workouts) {
    const s = (bySport[w.sport] ??= { sessions: 0, hours: 0, km: 0 });
    s.sessions += 1;
    s.hours += w.durationS / 3600;
    s.km += (w.distanceM ?? 0) / 1000;
  }
  for (const s of Object.values(bySport)) {
    s.hours = Math.round(s.hours * 10) / 10;
    s.km = Math.round(s.km * 10) / 10;
  }
  return { since: from, bySport };
}

/** One MCP server per request, bound to the athlete owning the connector URL. */
export function buildMcpServer(store: Store, user: User) {
  const server = new McpServer({ name: "coach", version: "0.1.0" }, { instructions: INSTRUCTIONS });
  const tz = () => user.profile.timezone ?? "UTC";
  const today = () => isoDate(new Date(), tz());

  server.registerTool(
    "get_athlete_overview",
    {
      title: "Vue d'ensemble de l'athlète",
      description: "Profil, objectif, date du jour, forme récente (sommeil, VFC, FC repos, VO2max), volume des 4 dernières semaines, séances prévues cette semaine et check-ins récents. À appeler en premier.",
      inputSchema: {},
    },
    async () => {
      const fresh = (await store.userById(user.id))!;
      const t = today();
      return text({
        today: t,
        timezone: tz(),
        profile: fresh.profile,
        recentMetrics: await store.dailyMetrics(user.id, 14, tz()),
        volumeLast4Weeks: await weeklyVolume(store, user, 4, tz()),
        upcomingSessions: await store.sessions(user.id, t, isoDate(addDays(new Date(), 7), tz())),
        recentCheckins: await store.checkins(user.id, 7, tz()),
        todayNote: await store.note(user.id, t),
      });
    }
  );

  server.registerTool(
    "list_workouts",
    {
      title: "Lister les séances réalisées",
      description: "Séances enregistrées (Apple Watch / Apple Santé), les plus récentes d'abord. Durées en secondes, distances en mètres.",
      inputSchema: {
        from: z.string().optional().describe("YYYY-MM-DD inclus"),
        to: z.string().optional().describe("YYYY-MM-DD inclus"),
        sport: Sport.optional(),
        limit: z.number().int().min(1).max(200).default(30),
      },
    },
    async ({ from, to, sport, limit }) => text(await store.listWorkouts(user.id, { from, to, sport, limit }))
  );

  server.registerTool(
    "get_workout",
    {
      title: "Détail d'une séance réalisée",
      description: "Données complètes d'une séance : tours/segments, temps par zone cardiaque, ressenti (RPE 1–10), séance prévue associée et analyse existante.",
      inputSchema: { id: z.string() },
    },
    async ({ id }) => {
      const workout = await store.workout(user.id, id);
      if (!workout) return { ...text(`Séance ${id} introuvable.`), isError: true };
      const planned = (await store.sessions(user.id)).find((s) => s.workoutId === id) ?? null;
      const analysis = (await store.analyses(user.id, [id]))[0] ?? null;
      return text({ workout, plannedSession: planned, analysis });
    }
  );

  server.registerTool(
    "get_daily_metrics",
    {
      title: "Métriques quotidiennes",
      description: "Sommeil (minutes), VFC (ms, SDNN), FC au repos, VO2max, jour par jour.",
      inputSchema: { days: z.number().int().min(1).max(365).default(30) },
    },
    async ({ days }) => text(await store.dailyMetrics(user.id, days, tz()))
  );

  server.registerTool(
    "get_plan",
    {
      title: "Programme",
      description: "Séances prévues (et réalisées, avec statut) sur une période.",
      inputSchema: {
        from: z.string().optional().describe("YYYY-MM-DD, défaut : il y a 7 jours"),
        to: z.string().optional().describe("YYYY-MM-DD, défaut : dans 28 jours"),
      },
    },
    async ({ from, to }) =>
      text(
        await store.sessions(
          user.id,
          from ?? isoDate(addDays(new Date(), -7), tz()),
          to ?? isoDate(addDays(new Date(), 28), tz())
        )
      )
  );

  server.registerTool(
    "upsert_sessions",
    {
      title: "Créer ou modifier des séances",
      description:
        "Crée (sans id) ou met à jour (avec id) des séances du programme. Chaque séance : date, sport, titre, durée, charge, why, cues, étapes. Exemple d'étape de fractionné : {name: '6 × 800 m', kind: 'work', zone: 4, distanceM: 800, repeat: 6, recovery: {durationMin: 2, zone: 1}, target: {paceSecPerKm: 245}}.",
      inputSchema: { sessions: z.array(SessionInput).min(1).max(60) },
    },
    async ({ sessions }) => {
      const saved = await store.upsertSessions(user.id, sessions);
      return text({ saved: saved.map((s) => ({ id: s.id, date: s.date, sport: s.sport, title: s.title })) });
    }
  );

  server.registerTool(
    "delete_sessions",
    {
      title: "Supprimer des séances",
      description: "Supprime des séances prévues par id. Préfère adapter une séance plutôt que la supprimer.",
      inputSchema: { ids: z.array(z.string()).min(1) },
    },
    async ({ ids }) => text({ deleted: await store.deleteSessions(user.id, ids) })
  );

  server.registerTool(
    "update_profile",
    {
      title: "Mettre à jour le profil",
      description: "Objectif (titre, date, temps visé), disponibilités, blessures/points d'attention, sports, FC max/repos, notes. Seuls les champs fournis sont modifiés.",
      inputSchema: Profile.omit({ timezone: true, language: true }).shape,
    },
    async (patch) => text(await store.updateProfile(user.id, patch))
  );

  server.registerTool(
    "get_readiness",
    {
      title: "Indicateurs de forme du matin",
      description: "VFC et FC repos (moyenne 7 j vs base 60 j, plage normale), sommeil de la nuit, charge d'entraînement aiguë 7 j vs chronique 28 j (ACWR). dataFresh=false si la nuit n'est pas encore synchronisée.",
      inputSchema: {},
    },
    async () => text(await computeReadiness(store, user.id, tz(), user.profile.maxHr ?? undefined))
  );

  server.registerTool(
    "set_daily_note",
    {
      title: "Écrire le mot du coach",
      description: "Le message du jour affiché en haut de l'app (2–3 phrases). Remplace celui du même jour.",
      inputSchema: {
        text: z.string().min(1).max(600),
        date: z.string().optional().describe("YYYY-MM-DD, défaut : aujourd'hui"),
      },
    },
    async ({ text: note, date }) => {
      const day = date ?? today();
      await store.setNote(user.id, day, note);
      return text({ ok: true, date: day });
    }
  );

  server.registerTool(
    "write_workout_analysis",
    {
      title: "Analyser une séance réalisée",
      description: "Analyse affichée dans le bilan de la séance : un texte (3–5 phrases) et 2–4 points clés (good / warning / next).",
      inputSchema: {
        workoutId: z.string(),
        text: z.string().min(1).max(1500),
        keyPoints: z.array(KeyPoint).max(5).default([]),
      },
    },
    async ({ workoutId, text: body, keyPoints }) => {
      if (!(await store.workout(user.id, workoutId))) {
        return { ...text(`Séance ${workoutId} introuvable.`), isError: true };
      }
      await store.setAnalysis(user.id, workoutId, body, keyPoints);
      return text({ ok: true });
    }
  );

  server.registerTool(
    "get_checkins",
    {
      title: "Ressentis de l'athlète",
      description: "Check-ins « comment tu te sens » (1 épuisé … 5 au top) envoyés depuis l'app.",
      inputSchema: { days: z.number().int().min(1).max(90).default(14) },
    },
    async ({ days }) => text(await store.checkins(user.id, days, tz()))
  );

  return server;
}
