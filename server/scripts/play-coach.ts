// Plays the coach through the MCP connector, exactly like Claude would (for local testing / demos).
//   npx tsx scripts/play-coach.ts <connectorUrl> plan [weeks] → goal + N weeks of sessions (default 2) + note of the day
//   npx tsx scripts/play-coach.ts <connectorUrl> analyze   → analyses for the latest workouts
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const [url, mode = "plan", weeksArg = "2"] = process.argv.slice(2);
const planWeeks = Math.max(1, Number(weeksArg) || 2);
if (!url) {
  console.error("usage: play-coach.ts <connectorUrl> [plan|analyze]");
  process.exit(1);
}

const client = new Client({ name: "coach-demo", version: "1.0.0" });
await client.connect(new StreamableHTTPClientTransport(new URL(url)));

const call = async (name: string, args: Record<string, unknown> = {}) => {
  const result = await client.callTool({ name, arguments: args });
  const text = (result.content as { text: string }[])[0]?.text ?? "";
  if (result.isError) throw new Error(`${name}: ${text}`);
  return text.startsWith("{") || text.startsWith("[") ? JSON.parse(text) : text;
};

const overview = await call("get_athlete_overview");
const today: string = overview.today;
const day = (offset: number) => {
  const d = new Date(`${today}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + offset);
  return d.toISOString().slice(0, 10);
};
// Monday of the current week
const weekday = (new Date(`${today}T12:00:00Z`).getUTCDay() + 6) % 7;
const monday = (week: number, offset: number) => day(-weekday + 7 * week + offset);

if (mode === "plan") {
  await call("update_profile", {
    name: "Léo",
    tagline: "Coureur · triathlète en herbe",
    goal: { title: "Semi-marathon de Paris", date: "2027-03-07", targetTime: "1 h 45" },
    availability: "5 à 6 séances / semaine, sortie longue le dimanche",
    injuries: "Mollet gauche un peu fragile",
    sports: ["course", "velo", "natation", "muscu"],
  });

  const week = (w: number) => [
    {
      date: monday(w, 0), sport: "velo", title: "Endurance vélo", subtitle: "Sortie souple en Z2", durationMin: 90, load: "Modérée",
      why: "Construire l'endurance sans impact pour les jambes.", target: { hrMin: 118, hrMax: 138 },
      cues: [{ title: "Reste en Z2", detail: "Tu dois pouvoir parler" }, { title: "Cadence 85–90 rpm" }],
      steps: [
        { name: "Échauffement", kind: "warmup", zone: 1, durationMin: 10 },
        { name: "Endurance", kind: "work", zone: 2, durationMin: 70, target: { hrMin: 118, hrMax: 138 } },
        { name: "Retour au calme", kind: "cooldown", zone: 1, durationMin: 10 },
      ],
    },
    {
      date: monday(w, 1), sport: "course", title: w === 0 ? "Fractionné 6 × 800 m" : "Fractionné 5 × 1000 m", subtitle: "Travail de VMA pour ton semi",
      durationMin: 55, load: "Élevée",
      why: "Les répétitions à allure VMA développent ta vitesse de base. C'est la séance clé de la semaine pour viser 1 h 45 sur semi.",
      target: { paceSecPerKm: 245, hrMin: 165, hrMax: 172, distanceKm: 10 },
      cues: [{ title: "4:05 /km sur chaque répétition" }, { title: "Récup en trottinant, sans t'arrêter" }],
      steps: [
        { name: "Échauffement", kind: "warmup", zone: 2, durationMin: 15, detail: "Footing souple" },
        w === 0
          ? { name: "6 × 800 m", kind: "work", zone: 4, distanceM: 800, repeat: 6, recovery: { durationMin: 2, zone: 1 }, target: { paceSecPerKm: 245 } }
          : { name: "5 × 1000 m", kind: "work", zone: 4, distanceM: 1000, repeat: 5, recovery: { durationMin: 2.5, zone: 1 }, target: { paceSecPerKm: 243 } },
        { name: "Retour au calme", kind: "cooldown", zone: 1, durationMin: 10, detail: "Très facile" },
      ],
    },
    {
      date: monday(w, 2), sport: "muscu", title: "Renfo bas du corps", subtitle: "Gainage et mollets", durationMin: 45, load: "Modérée",
      why: "Renforcer les mollets (point fragile) et la chaîne postérieure.",
      steps: [
        { name: "Mobilité", kind: "warmup", zone: 1, durationMin: 8 },
        { name: "Circuit · 4 tours", kind: "set", zone: 3, durationMin: 8, repeat: 4, detail: "Squats, fentes, montées de mollets, gainage", recovery: { durationMin: 1, zone: 1 } },
        { name: "Étirements", kind: "cooldown", zone: 1, durationMin: 5 },
      ],
    },
    {
      date: monday(w, 3), sport: "course", title: "Footing Z2", subtitle: "Récupération active", durationMin: 40, load: "Faible",
      why: "Faire tourner les jambes après le fractionné, sans fatigue supplémentaire.", target: { paceSecPerKm: 330, hrMin: 128, hrMax: 148 },
      steps: [{ name: "Footing", kind: "work", zone: 2, durationMin: 40, target: { hrMin: 128, hrMax: 148 } }],
    },
    { date: monday(w, 4), sport: "repos", title: "Repos", durationMin: 0, load: "Faible", why: "Le repos fait partie de l'entraînement." },
    {
      date: monday(w, 5), sport: "natation", title: "Technique crawl", subtitle: "Bassin 25 m", durationMin: 45, load: "Modérée",
      why: "Améliorer l'efficacité de nage, base du triathlon.", target: { swimPaceSecPer100m: 115, distanceKm: 1.8 },
      steps: [
        { name: "Échauffement", kind: "warmup", zone: 1, distanceM: 200, detail: "Crawl souple, respiration 3 temps" },
        { name: "Éducatifs", kind: "work", zone: 2, distanceM: 50, repeat: 4, detail: "Rattrapé", recovery: { durationMin: 0.33, zone: 1 } },
        { name: "Corps de séance", kind: "work", zone: 3, distanceM: 100, repeat: 8, recovery: { durationMin: 0.25, zone: 1 }, target: { swimPaceSecPer100m: 115 } },
        { name: "Retour au calme", kind: "cooldown", zone: 1, distanceM: 200, detail: "Dos ou brasse" },
      ],
    },
    {
      date: monday(w, 6), sport: "course", title: "Sortie longue", subtitle: "Endurance fondamentale", durationMin: 95 + w * 5, load: "Modérée",
      why: "Habituer le corps à la durée de l'effort du semi.", target: { paceSecPerKm: 340, hrMin: 130, hrMax: 150 },
      cues: [{ title: "Bois toutes les 20 min" }],
      steps: [{ name: "Sortie longue", kind: "work", zone: 2, durationMin: 95 + w * 5, target: { paceSecPerKm: 340 } }],
    },
  ];
  const all = Array.from({ length: planWeeks }, (_, w) => week(w)).flat();
  let savedCount = 0;
  for (let i = 0; i < all.length; i += 28) {
    savedCount += (await call("upsert_sessions", { sessions: all.slice(i, i + 28) })).saved.length;
  }
  const saved = { saved: { length: savedCount } };
  await call("set_daily_note", {
    text: "Belle nuit et VFC au-dessus de ta moyenne : on garde le fractionné prévu. Pars prudemment sur les 2 premières répétitions, la dernière doit être aussi rapide que la première.",
  });
  console.log(`plan: ${saved.saved.length} séances, note du jour écrite`);
}

if (mode === "analyze") {
  const workouts: any[] = await call("list_workouts", { limit: 5 });
  for (const w of workouts.slice(0, 3)) {
    const detail = await call("get_workout", { id: w.id });
    const km = (w.distanceM ?? 0) / 1000;
    const zones: number[] | undefined = w.details?.zonesMin;
    const z2 = zones ? Math.round((zones[1] / zones.reduce((a, b) => a + b, 0)) * 100) : null;
    await call("write_workout_analysis", {
      workoutId: w.id,
      text:
        w.sport === "course" && detail.plannedSession?.steps?.some((s: any) => s.repeat > 1)
          ? "Très bonne séance. Tu as tenu l'allure sur la plupart des répétitions et ta FC redescend bien pendant les récupérations : ton aérobie progresse. La dernière répétition montre un peu de fatigue, normal en semaine de charge."
          : `Séance de ${w.sport} bien menée (${km.toFixed(1)} km).${z2 != null ? ` ${z2} % du temps en Z2.` : ""} Continue comme ça, la régularité paie.`,
      keyPoints: [
        { kind: "good", text: "Séance réalisée comme prévu" },
        ...(w.rpe ? [{ kind: "warning", text: `Ressenti ${w.rpe}/10 : surveille la fatigue` }] : []),
        { kind: "next", text: "Prochaine séance : reste facile pour bien récupérer" },
      ],
    });
  }
  console.log(`analyze: ${Math.min(workouts.length, 3)} analyses écrites`);
}

await client.close();
