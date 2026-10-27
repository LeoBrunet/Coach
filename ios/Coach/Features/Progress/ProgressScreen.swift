import SwiftUI
import Charts

/// Design: UI Studio "Progrès" — Projection · Barres empilées · VO2max · Liste.
struct ProgressScreen: View {
    @Environment(AppModel.self) private var model
    @State private var weeks = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ErrorBanner()
                    Picker("Période", selection: $weeks) {
                        Text("4 sem.").tag(4)
                        Text("12 sem.").tag(12)
                        Text("Année").tag(52)
                    }
                    .pickerStyle(.segmented)
                    .studioComponent("Période")

                    goalSection

                    if model.workouts.isEmpty {
                        EmptyCard(icon: "heart.text.square", title: String(localized: "Pas encore de données"), message: model.healthAsked ? String(localized: "Tes séances Apple Watch apparaîtront ici après ta première séance.") : String(localized: "Autorise Apple Santé pour suivre tes progrès."))
                    } else {
                        volumeSection
                        formSection
                        recordsSection
                    }

                    CoachButton(title: String(localized: "Analyser mes progrès avec le coach"), kind: .secondary, showsHint: true) {
                        ClaudeLink.open(ClaudeLink.progress)
                    }
                }
                .padding(.horizontal, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.l)
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Progrès")
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }

    // MARK: Goal

    @ViewBuilder
    private var goalSection: some View {
        if let goal = model.profile.goal {
            let projected = Insights.projectedTime(model.workouts, goal: goal)
            let target = Insights.parseTime(goal.targetTime)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Label([goal.title, goal.date.flatMap(Day.date).map(Day.short)].compactMap { $0 }.joined(separator: " · "), systemImage: "flag.checkered")
                        .font(.dsHeadline)
                    Spacer()
                    if let projected, let target {
                        DSTag(text: projected <= target * 1.02 ? String(localized: "En bonne voie") : String(localized: "À travailler"), color: projected <= target * 1.02 ? .green : .orange)
                    }
                }
                if let projected {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text(Insights.formatRaceTime(projected)).font(.system(size: 34, weight: .heavy, design: .rounded))
                        Text("estimé\(goal.targetTime.map { " · objectif \($0)" } ?? "")").font(.dsCallout).foregroundStyle(.dsTextSecondary)
                    }
                    if let target {
                        let gap = projected - target
                        Text(gap > 0 ? String(localized: "Encore ~\(Int((gap / 60).rounded())) min à gagner") : String(localized: "Objectif à portée : \(Int((-gap / 60).rounded())) min d'avance"))
                            .font(.dsCaption)
                            .foregroundStyle(.dsTextSecondary)
                    }
                    Text("Projection à partir de ta meilleure course récente (formule de Riegel).")
                        .font(.dsCaption)
                        .foregroundStyle(.dsTextSecondary)
                } else if let date = goal.date.flatMap(Day.date) {
                    let days = Day.calendar.dateComponents([.day], from: Date(), to: date).day ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text("\(max(days, 0))").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(.dsAccent)
                        Text("jours restants").font(.dsCallout).foregroundStyle(.dsTextSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
            .studioComponent("Projection objectif")
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        let volumes = Insights.weeklyVolumes(model.workouts, weeks: weeks)
        let average = Insights.averageWeeklyHours(volumes)
        let sports = Insights.trainingSports
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader(title: String(localized: "Volume d'entraînement"), action: String(localized: "\(Fmt.duration(minutes: Int(average * 60))) / sem."))
            Chart(volumes) { item in
                BarMark(x: .value("Semaine", item.weekStart, unit: .weekOfYear), y: .value("Heures", item.hours))
                    .foregroundStyle(by: .value("Sport", item.sport.label))
            }
            .chartForegroundStyleScale(domain: sports.map(\.label), range: sports.map(\.color))
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: weeks > 12 ? 8 : weeks > 4 ? 3 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Double.self).map { Int($0) } ?? 0) h") }
                }
            }
            .chartLegend(position: .bottom, spacing: DS.Spacing.s)
            .frame(height: 200)
            .dsCard()
            .studioComponent("Graphique volume")
        }
    }

    // MARK: Form

    @ViewBuilder
    private var formSection: some View {
        let from = Day.string(Day.add(-7 * weeks, to: Date()))
        let series = model.metrics.filter { $0.vo2max != nil && $0.date >= from }.sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader(title: String(localized: "Forme"))
            if let last = series.last?.vo2max {
                let delta = series.first?.vo2max.map { last - $0 }
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.number(last, decimals: 1)).font(.system(size: 30, weight: .heavy, design: .rounded))
                        Text("VO2max · ml/kg/min").font(.dsCallout).foregroundStyle(.dsTextSecondary)
                        Spacer()
                        if let delta, abs(delta) >= 0.1 {
                            DSTag(text: String(localized: "\(delta > 0 ? "+" : "")\(Fmt.number(delta, decimals: 1)) sur la période"), color: delta > 0 ? .green : .orange)
                        }
                    }
                    let values = series.compactMap(\.vo2max)
                    let low = (values.min() ?? last) - 0.5, high = (values.max() ?? last) + 0.5
                    Chart(series, id: \.date) { point in
                        AreaMark(x: .value("Jour", Day.date(point.date) ?? Date()), yStart: .value("Base", low), yEnd: .value("VO2max", point.vo2max ?? 0))
                            .foregroundStyle(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Jour", Day.date(point.date) ?? Date()), y: .value("VO2max", point.vo2max ?? 0))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: low...high)
                    .chartXAxis(.hidden)
                    .frame(height: 120)
                }
                .dsCard()
                .studioComponent("Graphique VO2max")
            } else {
                EmptyCard(icon: "lungs", title: String(localized: "VO2max"), message: String(localized: "Ton Apple Watch estime ta VO2max lors de tes sorties en extérieur. Elle apparaîtra ici."))
            }
        }
    }

    // MARK: Records

    @ViewBuilder
    private var recordsSection: some View {
        let records = Insights.records(model.workouts)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Text("Records").font(.dsHeadline)
                    Spacer()
                    NavigationLink("Tout voir", value: Route.records).font(.dsCallout).foregroundStyle(.dsAccent)
                }
                RecordsList(records: Array(records.prefix(4)))
            }
        }
    }
}

struct RecordsList: View {
    let records: [Insights.Record]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: record.sport.icon).foregroundStyle(record.sport.color).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.dsBody)
                        Text(Day.short(record.date)).font(.dsCaption).foregroundStyle(.dsTextSecondary)
                    }
                    Spacer()
                    if record.isNew { DSTag(text: String(localized: "Nouveau")) }
                    Text(record.value).font(.system(.headline, design: .rounded))
                }
                .padding(.vertical, DS.Spacing.s)
                .studioComponent("Record · \(record.title)")
                if record.id != records.last?.id { Divider() }
            }
        }
        .dsCard(padding: DS.Spacing.s)
    }
}

/// "Tout voir": every record + the full workout history.
struct RecordsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Records") {
                ForEach(Insights.records(model.workouts)) { record in
                    HStack {
                        Image(systemName: record.sport.icon).foregroundStyle(record.sport.color)
                        Text(record.title)
                        Spacer()
                        Text(record.value).font(.headline)
                    }
                }
            }
            Section("Historique") {
                ForEach(model.workouts) { workout in
                    NavigationLink(value: Route.workout(workout.id)) {
                        HStack {
                            Image(systemName: workout.sport.icon).foregroundStyle(workout.sport.color).frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(model.session(forWorkout: workout.id)?.title ?? workout.sport.label)
                                Text(Day.long(workout.start)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(workout.distanceM.map { workout.sport == .natation ? "\(Int($0)) m" : "\(Fmt.km($0)) km" } ?? Fmt.clock(workout.durationS))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Records & historique")
    }
}
