import SwiftUI

/// Design: UI Studio "Programme" — Bannière · Grille.
struct ProgramView: View {
    @Environment(AppModel.self) private var model
    @State private var weekOffset = 0
    @State private var mode = Mode.week

    enum Mode: Hashable { case week, all }

    private var weekDays: [Date] { Day.week(containing: Day.add(7 * weekOffset, to: Date())) }
    private var weekSessions: [Session] { weekDays.flatMap { model.sessions(on: $0) } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ErrorBanner()
                    goalBanner
                    Picker("Affichage", selection: $mode) {
                        Text("Semaine").tag(Mode.week)
                        Text("Tout le plan").tag(Mode.all)
                    }
                    .pickerStyle(.segmented)
                    .studioComponent("Affichage")
                    if mode == .all {
                        FullPlanList(sessions: model.sessions, goal: model.profile.goal)
                    } else {
                    weekHeader
                    let planned = Insights.plannedMinutes(weekSessions)
                    if !planned.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(planned, id: \.sport) { item in volumeChip(item.sport, item.minutes) }
                            }
                        }
                        .scrollClipDisabled()
                    }
                    if weekSessions.isEmpty {
                        EmptyCard(
                            icon: "calendar.badge.plus",
                            title: String(localized: "Aucune séance cette semaine"),
                            message: model.sessions.isEmpty ? String(localized: "Ton coach n'a pas encore construit ton programme.") : String(localized: "Ton coach n'a rien prévu pour cette semaine."),
                            buttonTitle: String(localized: "Planifier avec le coach")
                        ) { ClaudeLink.open(model.sessions.isEmpty ? ClaudeLink.firstHello : ClaudeLink.editProgram + String(localized: "planifie la semaine du \(Day.short(weekDays[0])).")) }
                    } else {
                        weekGrid
                    }
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        if let updated = model.programUpdatedAt {
                            Label("Programme créé par Claude · mis à jour \(updated.formatted(.relative(presentation: .named)))", systemImage: "sparkles")
                                .font(.dsCaption)
                                .foregroundStyle(.dsTextSecondary)
                        }
                        CoachButton(title: String(localized: "Modifier avec le coach"), kind: .secondary) { ClaudeLink.open(ClaudeLink.editProgram) }
                    }
                }
                .padding(.horizontal, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.l)
            }
            .refreshable { await model.refresh() }
            .onChange(of: mode) { _, newMode in
                guard newMode == .all else { return }
                // Land on the current week (past weeks stay above).
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation { proxy.scrollTo(FullPlanList.weekID(Day.weekStart(Date())), anchor: .top) }
                }
            }
            }
            .navigationTitle("Programme")
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }

    // MARK: Goal

    @ViewBuilder
    private var goalBanner: some View {
        if let goal = model.profile.goal {
            let progress = blockProgress(goal: goal)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Image(systemName: "flag.checkered")
                    Text(goal.title).font(.dsHeadline)
                    Spacer()
                    if let date = goal.date.flatMap(Day.date) { Text(Day.short(date)).font(.dsCallout).opacity(0.85) }
                }
                if let target = goal.targetTime { Text("Objectif : \(target)").font(.dsTitle) }
                if let progress {
                    ProgressView(value: Double(progress.current), total: Double(progress.total)).tint(.white)
                    Text("Semaine \(progress.current) sur \(progress.total)").font(.dsCaption).opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(DS.Spacing.m)
            .background(
                LinearGradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.14), Color(red: 0.24, green: 0.2, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            )
            .studioComponent("Bannière objectif")
        } else {
            EmptyCard(icon: "flag.checkered", title: String(localized: "Pas encore d'objectif"), message: String(localized: "Dis à ton coach ce que tu prépares (course, distance, date)."), buttonTitle: String(localized: "Fixer un objectif")) {
                ClaudeLink.open(ClaudeLink.updateProfile + String(localized: "mon objectif est "))
            }
        }
    }

    /// Week index within the block: from the first planned session to the goal date.
    private func blockProgress(goal: Goal) -> (current: Int, total: Int)? {
        guard let first = model.sessions.compactMap(\.day).min(), let end = goal.date.flatMap(Day.date) else { return nil }
        let start = Day.weekStart(first)
        let total = max(Day.calendar.dateComponents([.weekOfYear], from: start, to: end).weekOfYear ?? 0, 0) + 1
        let current = (Day.calendar.dateComponents([.weekOfYear], from: start, to: Date()).weekOfYear ?? 0) + 1
        return (min(max(current, 1), total), total)
    }

    // MARK: Week

    private var weekHeader: some View {
        HStack {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left").padding(8) }
            Spacer()
            VStack(spacing: 2) {
                Text(weekOffset == 0 ? String(localized: "Cette semaine") : String(localized: "Semaine du \(Day.short(weekDays[0]))")).font(.dsHeadline)
                Text("\(weekSessions.filter { $0.sport != .repos }.count) séances · \(Fmt.duration(minutes: weekSessions.reduce(0) { $0 + $1.durationMin }))")
                    .font(.dsCaption)
                    .foregroundStyle(.dsTextSecondary)
            }
            .onTapGesture { weekOffset = 0 }
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right").padding(8) }
        }
        .studioComponent("Navigation semaine")
    }

    private func volumeChip(_ sport: Sport, _ minutes: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sport.icon).foregroundStyle(sport.color)
            Text(Fmt.duration(minutes: minutes)).font(.dsCallout.weight(.semibold))
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .background(sport.color.opacity(0.12), in: Capsule())
        .studioComponent("Volume · \(sport.label)")
    }

    private var weekGrid: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(weekDays, id: \.self) { day in
                let sessions = model.sessions(on: day)
                let isToday = Day.calendar.isDateInToday(day)
                VStack(spacing: DS.Spacing.xs) {
                    Text(Day.weekdayShort(day)).font(.dsCaption).foregroundStyle(isToday ? .dsAccent : .dsTextSecondary)
                    Text("\(Day.calendar.component(.day, from: day))").font(.system(.callout, design: .rounded, weight: .bold))
                    if sessions.isEmpty {
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(Color.dsSurface)
                            .frame(height: 40)
                            .overlay(Image(systemName: Sport.repos.icon).foregroundStyle(.dsTextSecondary).font(.caption))
                    }
                    ForEach(sessions) { session in
                        NavigationLink(value: session.isDone && session.workoutId != nil ? Route.workout(session.workoutId!) : Route.session(session.id)) {
                            dayCell(session, isToday: isToday)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .studioComponent("Grille semaine")
    }

    private func dayCell(_ session: Session, isToday: Bool) -> some View {
        let rest = session.sport == .repos
        return VStack(spacing: 6) {
            Image(systemName: session.sport.icon).font(.title3)
            if session.durationMin > 0 {
                Text("\(session.durationMin)'").font(.system(.caption, design: .rounded, weight: .semibold))
            }
            if session.isDone {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(rest ? Color.dsTextSecondary : .white)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(max(session.durationMin, 30)) * 1.3)
        .background(rest ? Color.dsSurface : session.sport.color, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).stroke(Color.dsTextPrimary, lineWidth: 2)
            }
        }
        .opacity(session.isDone ? 0.75 : 1)
    }
}

// MARK: - Whole plan

/// Every planned week, from the first session to the goal, grouped by week.
struct FullPlanList: View {
    let sessions: [Session]
    let goal: Goal?

    static func weekID(_ start: Date) -> String { "week-\(Day.string(start))" }

    private var weeks: [(start: Date, sessions: [Session])] {
        let grouped = Dictionary(grouping: sessions.filter { $0.day != nil }) { Day.weekStart($0.day!) }
        return grouped.keys.sorted().map { start in (start, grouped[start]!.sorted { $0.date < $1.date }) }
    }

    var body: some View {
        let goalDate = goal?.date.flatMap(Day.date)
        if weeks.isEmpty {
            EmptyCard(icon: "calendar.badge.plus", title: String(localized: "Aucune séance prévue"), message: String(localized: "Ton coach n'a pas encore construit ton programme."), buttonTitle: String(localized: "Demander un programme")) {
                ClaudeLink.open(ClaudeLink.firstHello)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.l) {
                ForEach(Array(weeks.enumerated()), id: \.element.start) { index, week in
                    let isCurrent = Day.calendar.isDate(week.start, equalTo: Date(), toGranularity: .weekOfYear)
                    let isPast = Day.add(7, to: week.start) <= Day.calendar.startOfDay(for: Date())
                    let containsGoal = goalDate.map { $0 >= week.start && $0 < Day.add(7, to: week.start) } ?? false
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Semaine \(index + 1)").font(.dsHeadline)
                            Text(isCurrent ? String(localized: "· cette semaine") : "· du \(Day.short(week.start))")
                                .font(.dsCallout)
                                .foregroundStyle(isCurrent ? .dsAccent : .dsTextSecondary)
                            Spacer()
                            Text(Fmt.duration(minutes: week.sessions.reduce(0) { $0 + $1.durationMin }))
                                .font(.dsCaption)
                                .foregroundStyle(.dsTextSecondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(week.sessions) { session in
                                PlanRow(session: session, isGoalDay: goalDate.map { Day.calendar.isDate($0, inSameDayAs: session.day!) } ?? false)
                                if session.id != week.sessions.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                        .dsCard(padding: DS.Spacing.xs)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).stroke(Color.dsAccent, lineWidth: 1.5)
                            }
                        }
                        if containsGoal, let goal {
                            Label("\(goal.title)\(goal.targetTime.map { " · \($0)" } ?? "")", systemImage: "flag.checkered")
                                .font(.dsCallout.weight(.semibold))
                                .foregroundStyle(.dsAccent)
                                .padding(.top, DS.Spacing.xxs)
                        }
                    }
                    .opacity(isPast && !isCurrent ? 0.7 : 1)
                    .id(Self.weekID(week.start))
                    .studioComponent("Semaine \(index + 1)")
                }
            }
        }
    }
}

private struct PlanRow: View {
    let session: Session
    let isGoalDay: Bool

    var body: some View {
        let day = session.day ?? Date()
        let isToday = Day.calendar.isDateInToday(day)
        NavigationLink(value: session.isDone && session.workoutId != nil ? Route.workout(session.workoutId!) : Route.session(session.id)) {
            HStack(spacing: DS.Spacing.s) {
                VStack(spacing: 0) {
                    Text(Day.weekdayShort(day)).font(.dsCaption).foregroundStyle(isToday ? .dsAccent : .dsTextSecondary)
                    Text("\(Day.calendar.component(.day, from: day))").font(.system(.callout, design: .rounded, weight: .bold))
                }
                .frame(width: 36)
                Image(systemName: isGoalDay ? "flag.checkered" : session.sport.icon)
                    .font(.callout)
                    .foregroundStyle(session.sport == .repos ? Color.dsTextSecondary : .white)
                    .frame(width: 32, height: 32)
                    .background(session.sport == .repos ? Color.dsSurface : isGoalDay ? Color.dsAccent : session.sport.color, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.dsCallout.weight(.semibold)).lineLimit(1)
                    if session.durationMin > 0 {
                        Text("\(session.sport.label) · \(Fmt.duration(minutes: session.durationMin))").font(.dsCaption).foregroundStyle(.dsTextSecondary)
                    }
                }
                Spacer(minLength: 4)
                if session.isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if isToday {
                    DSTag(text: String(localized: "Aujourd'hui"))
                } else if session.sport != .repos {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.dsTextSecondary)
                }
            }
            .padding(.vertical, DS.Spacing.xs)
            .padding(.horizontal, DS.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
