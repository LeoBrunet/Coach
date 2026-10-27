import SwiftUI

/// Design: UI Studio "Séance · avant" — Étapes · Tuiles + pourquoi (v1) · bouton Apple Watch.
struct SessionBriefView: View {
    let sessionId: String
    @Environment(AppModel.self) private var model
    @State private var sending = false
    @State private var alert: (title: String, message: String)?

    private var session: Session? { model.sessions.first { $0.id == sessionId } }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ContentUnavailableView("Séance introuvable", systemImage: "calendar.badge.exclamationmark", description: Text("Elle a peut-être été modifiée par le coach."))
            }
        }
        .navigationTitle("Séance")
        .navigationBarTitleDisplayMode(.inline)
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func content(_ session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Label(session.sport.label, systemImage: session.sport.icon)
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(session.sport.color)
                    Text(session.title).font(.dsDisplay)
                    Text([session.day.map(Day.long), Fmt.duration(minutes: session.durationMin), session.loadLabel.map { String(localized: "Charge \($0.lowercased())") }].compactMap { $0 }.joined(separator: " · "))
                        .font(.dsCallout)
                        .foregroundStyle(.dsTextSecondary)
                }
                .padding(.top, DS.Spacing.s)
                .studioComponent("En-tête séance")

                if let steps = session.steps, !steps.isEmpty {
                    StepsList(steps: steps, sport: session.sport)
                } else {
                    EmptyCard(icon: "list.number", title: String(localized: "Séance libre"), message: String(localized: "Le coach n'a pas détaillé les étapes de cette séance."), buttonTitle: String(localized: "Demander le détail")) {
                        ClaudeLink.open(String(localized: "Coach, peux-tu détailler les étapes de ma séance « \(session.title) » (id \(session.id)) ?"))
                    }
                }

                let tiles = self.tiles(session)
                if !tiles.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(tiles, id: \.label) { DSMetricTile(label: $0.label, value: $0.value, unit: $0.unit) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let why = session.why, !why.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Label("Pourquoi cette séance", systemImage: "sparkles")
                            .font(.dsHeadline)
                            .foregroundStyle(.dsAccent)
                        Text(why).font(.dsBody)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard()
                    .studioComponent("Pourquoi cette séance")
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if session.isDone, let workoutId = session.workoutId {
                    NavigationLink(value: Route.workout(workoutId)) {
                        Label("Voir le bilan", systemImage: "chart.bar.xaxis")
                    }
                    .buttonStyle(.dsPrimary)
                } else if session.sport != .repos {
                    Button { send(session) } label: {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Label("Envoyer sur l'Apple Watch", systemImage: "applewatch")
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(sending)
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(.bar)
        }
    }

    private func tiles(_ session: Session) -> [(label: String, value: String, unit: String?)] {
        let target = session.target
        let workPace = target?.paceSecPerKm ?? session.steps?.compactMap { $0.target?.paceSecPerKm }.first
        var tiles: [(label: String, value: String, unit: String?)] = []
        if let workPace { tiles.append((String(localized: "Allure cible"), Fmt.pace(workPace), "/km")) }
        if let swim = target?.swimPaceSecPer100m { tiles.append((String(localized: "Allure cible"), Fmt.pace(swim), "/100 m")) }
        if let speed = target?.speedKmh { tiles.append((String(localized: "Vitesse"), Fmt.number(speed, decimals: 1), "km/h")) }
        if let low = target?.hrMin, let high = target?.hrMax { tiles.append((String(localized: "FC cible"), "\(low)–\(high)", "bpm")) }
        if let distance = target?.distanceKm {
            tiles.append((String(localized: "Distance"), session.sport == .natation ? "\(Int(distance * 1000))" : "~\(Fmt.number(distance, decimals: distance < 10 ? 1 : 0))", session.sport == .natation ? "m" : "km"))
        } else if session.sport == .natation, let total = session.steps?.reduce(0, { $0 + ($1.distanceM ?? 0) * Double($1.repeatCount) }), total > 0 {
            tiles.append((String(localized: "Distance"), "\(Int(total))", "m"))
        }
        return Array(tiles.prefix(3))
    }

    private func send(_ session: Session) {
        sending = true
        Task {
            defer { sending = false }
            do {
                let when = try await WatchScheduler.send(session)
                let day = Calendar.current.date(from: when).map(Day.long) ?? ""
                alert = (String(localized: "Séance envoyée"), String(localized: "« \(session.title) » est programmée sur ta montre (\(day)). Ouvre l'app Exercice sur l'Apple Watch pour la lancer."))
            } catch {
                alert = (String(localized: "Envoi impossible"), error.localizedDescription)
            }
        }
    }
}
