import SwiftUI

/// Design: UI Studio "Aujourd'hui" — Carte héro · Score unique · Le mot du coach.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDay = Day.calendar.startOfDay(for: Date())

    private var isToday: Bool { Day.calendar.isDateInToday(selectedDay) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ErrorBanner()
                    WeekStrip(selected: $selectedDay)
                    sessionSection
                    if isToday {
                        recoverySection
                        coachSection
                    }
                }
                .padding(.horizontal, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.l)
            }
            .refreshable { await model.refresh() }
            .navigationTitle(isToday ? String(localized: "Aujourd'hui") : Day.long(selectedDay))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.selectedTab = .profile } label: {
                        DSAvatar(initials: initials(model.profile.name), size: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }

    // MARK: Session

    @ViewBuilder
    private var sessionSection: some View {
        let sessions = model.sessions(on: selectedDay)
        let unplanned = model.workouts(on: selectedDay).filter { w in !sessions.contains { $0.workoutId == w.id } }
        if let session = sessions.first {
            HeroSessionCard(session: session)
            ForEach(sessions.dropFirst()) { CompactSessionRow(session: $0) }
        } else if !unplanned.isEmpty {
            // Nothing planned, but a workout was done that day: just show it below.
            EmptyView()
        } else if model.sessions.isEmpty && selectedDay >= Day.calendar.startOfDay(for: Date()) {
            EmptyCard(
                icon: "sparkles",
                title: String(localized: "Pas encore de programme"),
                message: String(localized: "Ton coach construit ton programme dans Claude à partir de tes données et de ton objectif."),
                buttonTitle: String(localized: "Demander un programme au coach")
            ) { ClaudeLink.open(ClaudeLink.firstHello) }
        } else {
            EmptyCard(icon: Sport.repos.icon, title: String(localized: "Repos"), message: String(localized: "Aucune séance prévue ce jour-là. Récupère bien !"))
        }
        ForEach(unplanned) { workout in
            NavigationLink(value: Route.workout(workout.id)) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: workout.sport.icon).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(workout.sport.color.gradient, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(workout.sport.label) libre").font(.dsHeadline)
                        Text("\(Fmt.duration(minutes: Int(workout.durationS / 60)))\(workout.distanceM.map { " · \(Fmt.km($0)) km" } ?? "")")
                            .font(.dsCallout).foregroundStyle(.dsTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.dsTextSecondary)
                }
                .dsCard(padding: DS.Spacing.s)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Recovery

    @ViewBuilder
    private var recoverySection: some View {
        if let recovery = Insights.recovery(model.metrics) {
            HStack(spacing: DS.Spacing.m) {
                ZStack {
                    DSRing(progress: Double(recovery.score) / 100, color: recovery.score >= 75 ? .green : recovery.score >= 55 ? .orange : .red, lineWidth: 9)
                    VStack(spacing: 0) {
                        Text("\(recovery.score)").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("/100").font(.dsCaption).foregroundStyle(.dsTextSecondary)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Forme : \(recovery.label)").font(.dsHeadline)
                    Text(recovery.summary).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .dsCard()
            .studioComponent("Récupération (score)")
        } else if !model.healthAsked {
            EmptyCard(icon: "heart.text.square", title: String(localized: "Récupération"), message: String(localized: "Autorise Apple Santé pour suivre ton sommeil, ta VFC et ta FC au repos."))
                .overlay(alignment: .bottomTrailing) {
                    Button("Autoriser") { Task { await model.requestHealthAccess() } }
                        .font(.dsCallout.weight(.semibold))
                        .padding(DS.Spacing.m)
                }
        }
    }

    // MARK: Coach

    private var coachSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Label("Le mot du coach", systemImage: "sparkles")
                    .font(.dsHeadline)
                    .foregroundStyle(.dsAccent)
                Spacer()
                if let note = model.note {
                    Text(Fmt.time(isoString: note.createdAt)).font(.dsCaption).foregroundStyle(.dsTextSecondary)
                }
            }
            if let note = model.note {
                Text(note.text).font(.dsBody)
                CoachButton(title: String(localized: "Une question avant de partir ?"), kind: .secondary, showsHint: true) {
                    ClaudeLink.open(ClaudeLink.beforeSession(model.sessions(on: Date()).first))
                }
            } else {
                Text("Ton coach n'a pas encore écrit aujourd'hui.").font(.dsBody).foregroundStyle(.dsTextSecondary)
                CoachButton(title: String(localized: "Demander le point du jour"), kind: .secondary, showsHint: true) {
                    ClaudeLink.open(ClaudeLink.dailyNote)
                }
            }
        }
        .dsCard()
        .studioComponent("Mot du coach")
    }

    private func initials(_ name: String?) -> String {
        let letters = (name ?? String(localized: "Moi")).split(separator: " ").compactMap(\.first).prefix(2)
        return String(letters).uppercased()
    }
}

// MARK: - Week strip

/// The week containing `selected`, with arrows (and a horizontal swipe) to move between weeks.
struct WeekStrip: View {
    @Binding var selected: Date
    @Environment(AppModel.self) private var model

    private var week: [Date] { Day.week(containing: selected) }
    private var isCurrentWeek: Bool { Day.calendar.isDate(selected, equalTo: Date(), toGranularity: .weekOfYear) }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Button { move(weeks: -1) } label: { Image(systemName: "chevron.left").padding(6) }
                    .accessibilityLabel("Semaine précédente")
                Spacer()
                Button {
                    selected = Day.calendar.startOfDay(for: Date())
                } label: {
                    VStack(spacing: 0) {
                        Text(isCurrentWeek ? String(localized: "Cette semaine") : String(localized: "Semaine du \(Day.short(week[0]))"))
                            .font(.dsCallout.weight(.semibold))
                            .foregroundStyle(.dsTextPrimary)
                        if !isCurrentWeek {
                            Text("Revenir à aujourd'hui").font(.dsCaption).foregroundStyle(.dsAccent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCurrentWeek && Day.calendar.isDateInToday(selected))
                Spacer()
                Button { move(weeks: 1) } label: { Image(systemName: "chevron.right").padding(6) }
                    .accessibilityLabel("Semaine suivante")
            }
            .font(.dsCallout.weight(.semibold))

            HStack(spacing: 0) {
                ForEach(week, id: \.self) { day in
                    let isSelected = Day.calendar.isDate(day, inSameDayAs: selected)
                    let sessions = model.sessions(on: day)
                    let done = sessions.contains(where: \.isDone) || (!model.workouts(on: day).isEmpty && sessions.allSatisfy(\.isDone))
                    Button { selected = day } label: {
                        VStack(spacing: 6) {
                            Text(Day.weekdayLetter(day)).font(.dsCaption).foregroundStyle(.dsTextSecondary)
                            Text("\(Day.calendar.component(.day, from: day))")
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .foregroundStyle(isSelected ? .white : Day.calendar.isDateInToday(day) ? .dsAccent : .dsTextPrimary)
                                .frame(width: 34, height: 34)
                                .background(isSelected ? Color.dsAccent : .clear, in: Circle())
                            Group {
                                if done {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if let sport = sessions.first?.sport {
                                    Image(systemName: sport.icon).foregroundStyle(sport.color)
                                } else {
                                    Color.clear
                                }
                            }
                            .font(.caption)
                            .frame(height: 14)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    move(weeks: value.translation.width < 0 ? 1 : -1)
                }
        )
        .animation(.snappy(duration: 0.2), value: week.first)
        .studioComponent("Semaine")
    }

    /// Same weekday, `weeks` weeks earlier/later.
    private func move(weeks: Int) {
        selected = Day.add(7 * weeks, to: selected)
    }
}

// MARK: - Session cards

struct HeroSessionCard: View {
    let session: Session

    var body: some View {
        let steps = session.steps ?? []
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Label(session.sport.label, systemImage: session.sport.icon)
                    .font(.dsCaption.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(.white.opacity(0.2), in: Capsule())
                Spacer()
                if session.isDone {
                    Label("Fait", systemImage: "checkmark.circle.fill").font(.dsCallout.weight(.semibold))
                } else {
                    Text(Fmt.duration(minutes: session.durationMin)).font(.dsCallout.weight(.semibold))
                }
            }
            Text(session.title).font(.dsTitle)
            if let subtitle = session.subtitle { Text(subtitle).font(.dsCallout).opacity(0.85) }
            if !steps.isEmpty {
                IntensityBar(segments: Insights.segments(steps, sport: session.sport), monochrome: true)
                    .frame(height: 40)
                    .padding(.vertical, DS.Spacing.xs)
            }
            HStack {
                metric(String(localized: "Allure"), paceText)
                metric(String(localized: "Zone"), steps.map(\.zone).max().map { "Z\($0)" } ?? "–")
                metric(String(localized: "Charge"), session.loadLabel ?? "–")
            }
            NavigationLink(value: session.isDone && session.workoutId != nil ? Route.workout(session.workoutId!) : Route.session(session.id)) {
                Text(session.isDone ? String(localized: "Voir le bilan") : String(localized: "Voir la séance"))
                    .font(.dsHeadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.s)
                    .foregroundStyle(session.sport.color)
                    .background(.white, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Spacing.xs)
        }
        .foregroundStyle(.white)
        .padding(DS.Spacing.m)
        .background(
            LinearGradient(colors: [session.sport.color, session.sport.color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        )
        .studioComponent("Carte séance (héro)")
    }

    private var paceText: String {
        if let pace = session.target?.paceSecPerKm ?? session.steps?.compactMap({ $0.target?.paceSecPerKm }).first { return "\(Fmt.pace(pace)) /km" }
        if let swim = session.target?.swimPaceSecPer100m { return "\(Fmt.pace(swim)) /100 m" }
        if let speed = session.target?.speedKmh { return "\(Fmt.number(speed)) km/h" }
        return String(localized: "Libre")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.dsCaption).opacity(0.8)
            Text(value).font(.dsHeadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactSessionRow: View {
    let session: Session

    var body: some View {
        NavigationLink(value: session.isDone && session.workoutId != nil ? Route.workout(session.workoutId!) : Route.session(session.id)) {
            HStack(spacing: DS.Spacing.s) {
                RoundedRectangle(cornerRadius: 3).fill(session.sport.color).frame(width: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.sport.label.uppercased()).font(.dsCaption).foregroundStyle(session.sport.color)
                    Text(session.title).font(.dsHeadline)
                    Text(Fmt.duration(minutes: session.durationMin)).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                }
                Spacer()
                Image(systemName: session.isDone ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(session.isDone ? .green : .dsTextSecondary)
            }
            .frame(height: 64)
            .dsCard(padding: DS.Spacing.s)
        }
        .buttonStyle(.plain)
    }
}
