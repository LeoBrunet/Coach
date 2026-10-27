import SwiftUI
import Charts
import MapKit

/// Design: UI Studio "Séance · bilan" (+ "Séance vélo · bilan" for the route and zones).
struct SessionDebriefView: View {
    let workoutId: String
    @Environment(AppModel.self) private var model
    @State private var route: [CLLocationCoordinate2D] = []

    private var workout: WorkoutSummary? { model.workout(id: workoutId) }
    private var session: Session? { model.session(forWorkout: workoutId) }

    var body: some View {
        Group {
            if let workout {
                content(workout)
            } else {
                ContentUnavailableView("Séance introuvable", systemImage: "applewatch.slash", description: Text("Synchronise Apple Santé depuis l'onglet Aujourd'hui."))
            }
        }
        .navigationTitle("Bilan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let workout {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(workout)) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { await model.refreshState() }
        .task(id: workoutId) {
            guard let workout, workout.sport == .course || workout.sport == .velo else { return }
            route = (try? await model.health.route(forWorkoutID: workoutId))?.map(\.coordinate) ?? []
        }
    }

    private var title: String { session?.title ?? (workout.map { String(localized: "\($0.sport.label) libre") } ?? String(localized: "Séance libre")) }

    private func content(_ workout: WorkoutSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Label("Séance terminée", systemImage: "checkmark.seal.fill")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(title).font(.dsDisplay)
                    Label("\(Day.long(workout.start)) · \(workout.start.formatted(date: .omitted, time: .shortened)) · Apple Watch", systemImage: workout.sport == .velo ? Sport.velo.icon : "applewatch")
                        .font(.dsCallout)
                        .foregroundStyle(.dsTextSecondary)
                }
                .padding(.top, DS.Spacing.s)
                .studioComponent("En-tête bilan")

                if route.count > 2 { routeMap(workout.sport) }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 3), spacing: DS.Spacing.xs) {
                    ForEach(tiles(workout), id: \.label) { DSMetricTile(label: $0.label, value: $0.value, unit: $0.unit) }
                }

                if let comparison = repComparison(workout) {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        SectionHeader(title: String(localized: "Réalisé vs prévu"))
                        repsChart(comparison)
                    }
                }

                if let zones = workout.details.zonesMin, zones.reduce(0, +) > 0 {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        SectionHeader(title: String(localized: "Temps en zones"), action: String(localized: "FC max \(model.maxHr)"))
                        zoneBars(zones)
                    }
                }

                analysisSection(workout)
                effortPicker(workout)

                CoachButton(title: String(localized: "Débriefer avec le coach"), showsHint: true) {
                    ClaudeLink.open(ClaudeLink.debrief(workoutId: workout.id, title: title))
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.l)
        }
        .refreshable { await model.refreshState() }
    }

    // MARK: Tiles

    private func tiles(_ w: WorkoutSummary) -> [(label: String, value: String, unit: String?)] {
        var tiles: [(label: String, value: String, unit: String?)] = []
        switch w.sport {
        case .natation:
            if let d = w.distanceM { tiles.append((String(localized: "Distance"), "\(Int(d))", "m")) }
        case .course, .velo:
            if let d = w.distanceM { tiles.append((String(localized: "Distance"), Fmt.km(d), "km")) }
        default: break
        }
        tiles.append((String(localized: "Durée"), Fmt.clock(w.durationS), nil))
        switch w.sport {
        case .course:
            if let pace = w.paceSecPerKm { tiles.append((String(localized: "Allure moy."), Fmt.pace(pace), "/km")) }
        case .velo:
            if let speed = w.speedKmh { tiles.append((String(localized: "Vitesse moy."), Fmt.number(speed, decimals: 1), "km/h")) }
        case .natation:
            if let d = w.distanceM, d > 0 { tiles.append((String(localized: "Allure moy."), Fmt.pace(Int(w.durationS / d * 100)), "/100 m")) }
        default: break
        }
        if let hr = w.avgHr { tiles.append((String(localized: "FC moy."), "\(Int(hr))", "bpm")) }
        if w.sport == .velo, let elevation = w.elevationM {
            tiles.append((String(localized: "Dénivelé"), "\(Int(elevation))", "m"))
        } else if let hr = w.maxHr {
            tiles.append((String(localized: "FC max"), "\(Int(hr))", "bpm"))
        }
        if let kcal = w.energyKcal { tiles.append((String(localized: "Calories"), "\(Int(kcal))", "kcal")) }
        return tiles
    }

    // MARK: Route

    private func routeMap(_ sport: Sport) -> some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: route)
                .stroke(sport.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = route.first {
                Annotation(String(localized: "Départ"), coordinate: first) {
                    Circle().fill(.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .studioComponent("Carte du parcours")
    }

    // MARK: Reps vs plan

    private struct RepComparison {
        let target: Int
        let reps: [(index: Int, pace: Int)]
    }

    /// Matches the watch's interval segments to the planned repeated step (e.g. 6 × 800 m @ 4:05).
    private func repComparison(_ w: WorkoutSummary) -> RepComparison? {
        guard w.sport == .course,
              let step = session?.steps?.first(where: { $0.repeatCount > 1 && $0.distanceM != nil }),
              let distance = step.distanceM,
              let target = step.target?.paceSecPerKm ?? session?.target?.paceSecPerKm,
              let laps = w.details.laps else { return nil }
        let matching = laps.filter { lap in
            guard let d = lap.distanceM else { return false }
            return abs(d - distance) / distance < 0.15
        }
        guard !matching.isEmpty else { return nil }
        return RepComparison(target: target, reps: matching.prefix(step.repeatCount).enumerated().compactMap { index, lap in
            lap.paceSecPerKm.map { (index + 1, $0) }
        })
    }

    private func repsChart(_ c: RepComparison) -> some View {
        let paces = c.reps.map(\.pace) + [c.target]
        let low = (paces.min() ?? c.target) - 8, high = (paces.max() ?? c.target) + 6
        return Chart {
            ForEach(c.reps, id: \.index) { rep in
                BarMark(
                    x: .value("Répétition", "R\(rep.index)"),
                    yStart: .value("Base", low),
                    yEnd: .value("Allure", rep.pace),
                    width: .ratio(0.55)
                )
                .foregroundStyle(abs(rep.pace - c.target) <= 3 ? Color.green : Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            RuleMark(y: .value("Cible", c.target))
                .foregroundStyle(Color.dsTextPrimary)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Cible \(Fmt.pace(c.target))").font(.dsCaption).foregroundStyle(.dsTextSecondary)
                }
        }
        .chartYScale(domain: low...high)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { Text(Fmt.pace(value.as(Int.self) ?? 0)) }
            }
        }
        .frame(height: 170)
        .dsCard()
        .studioComponent("Graphique réalisé vs prévu")
    }

    // MARK: Zones

    private func zoneBars(_ zones: [Double]) -> some View {
        let total = max(zones.reduce(0, +), 1)
        let ranges = HRZones.ranges(maxHr: model.maxHr)
        return VStack(spacing: DS.Spacing.xs) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: DS.Spacing.s) {
                    Text("Z\(index + 1)")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 24)
                        .background(Color.dsZone(index + 1), in: RoundedRectangle(cornerRadius: 6))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.dsSurface)
                            Capsule().fill(Color.dsZone(index + 1))
                                .frame(width: zones[index] > 0 ? max(geo.size.width * zones[index] / total, 6) : 0)
                        }
                    }
                    .frame(height: 10)
                    Text("\(Int(zones[index].rounded())) min")
                        .font(.dsCallout.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
                .help(ranges[index])
            }
        }
        .dsCard(padding: DS.Spacing.s)
        .studioComponent("Temps en zones")
    }

    // MARK: Analysis

    @ViewBuilder
    private func analysisSection(_ w: WorkoutSummary) -> some View {
        if let analysis = model.analysis(for: w.id) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Label("Analyse du coach", systemImage: "sparkles")
                    .font(.dsHeadline)
                    .foregroundStyle(.dsAccent)
                Text(analysis.text).font(.dsBody)
                ForEach(analysis.keyPoints, id: \.self) { point in
                    HStack(alignment: .top, spacing: DS.Spacing.s) {
                        Image(systemName: point.kind == "good" ? "checkmark.circle.fill" : point.kind == "warning" ? "exclamationmark.circle.fill" : "arrow.right.circle.fill")
                            .foregroundStyle(point.kind == "good" ? Color.green : point.kind == "warning" ? .orange : .dsAccent)
                        Text(point.text).font(.dsCallout)
                    }
                }
                Text("Rédigé par Claude · \(Fmt.time(isoString: analysis.createdAt))")
                    .font(.dsCaption)
                    .foregroundStyle(.dsTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
            .studioComponent("Analyse du coach")
        } else {
            EmptyCard(icon: "sparkles", title: String(localized: "Analyse du coach"), message: String(localized: "Pas encore d'analyse. Demande au coach de débriefer cette séance : elle apparaîtra ici."))
        }
    }

    private func effortPicker(_ w: WorkoutSummary) -> some View {
        let effort = model.state?.rpe[w.id] ?? 0
        let labels = ["", String(localized: "Très facile"), String(localized: "Facile"), String(localized: "Facile"), String(localized: "Modéré"), String(localized: "Modéré"), String(localized: "Soutenu"), String(localized: "Difficile"), String(localized: "Très difficile"), String(localized: "Très difficile"), String(localized: "Maximal")]
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Text("Effort ressenti").font(.dsHeadline)
                Spacer()
                Text(effort > 0 ? "\(effort)/10 · \(labels[effort])" : String(localized: "Touche pour noter"))
                    .font(.dsCallout)
                    .foregroundStyle(.dsTextSecondary)
            }
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { value in
                    Button { Task { await model.setRPE(value, for: w.id) } } label: {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(value <= effort ? Color.dsZone((value + 1) / 2) : Color.dsSurface)
                            .frame(height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .studioComponent("Effort ressenti")
    }

    private func shareText(_ w: WorkoutSummary) -> String {
        var parts = ["\(title) — \(Day.long(w.start))", String(localized: "Durée \(Fmt.clock(w.durationS))")]
        if let d = w.distanceM { parts.append(w.sport == .natation ? "\(Int(d)) m" : "\(Fmt.km(d)) km") }
        if let pace = w.paceSecPerKm, w.sport == .course { parts.append("\(Fmt.pace(pace)) /km") }
        if let hr = w.avgHr { parts.append(String(localized: "FC moy. \(Int(hr)) bpm")) }
        return parts.joined(separator: " · ")
    }
}
