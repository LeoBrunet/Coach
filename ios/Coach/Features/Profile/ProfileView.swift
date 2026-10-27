import SwiftUI
import WorkoutKit

/// Design: UI Studio "Profil" — En-tête centré · Connexions (liste) · Zones FC (barres).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var watchState: WorkoutScheduler.AuthorizationState?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ErrorBanner()
                    header
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        SectionHeader(title: String(localized: "Connexions"))
                        connections
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        SectionHeader(title: String(localized: "Mon profil sportif"), action: String(localized: "Modifier")) { editing = true }
                        VStack(spacing: 0) {
                            infoRow("flag.checkered", String(localized: "Objectif"), goalText)
                            Divider()
                            infoRow("calendar", String(localized: "Disponibilités"), model.profile.availability ?? String(localized: "Non renseignées"))
                            Divider()
                            infoRow("bandage", String(localized: "Points d'attention"), model.profile.injuries ?? String(localized: "Aucun"))
                        }
                        .dsCard(padding: DS.Spacing.s)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(sports, id: \.self) { DSChip(text: $0.label, icon: $0.icon) }
                            }
                        }
                        .scrollClipDisabled()
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        SectionHeader(title: String(localized: "Zones cardiaques"), action: String(localized: "FC max \(model.maxHr)"))
                        zones
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        CoachButton(title: String(localized: "Mettre à jour avec le coach"), kind: .secondary) { ClaudeLink.open(ClaudeLink.updateProfile) }
                        Text("Le coach adapte ton programme à ces informations.")
                            .font(.dsCaption)
                            .foregroundStyle(.dsTextSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Spacing.m)
                .padding(.bottom, DS.Spacing.l)
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $editing) { ProfileEditView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showConnect) { ConnectClaudeView(mode: .sheet) }
            .task { watchState = WatchScheduler.isSupported ? await WatchScheduler.authorizationState() : nil }
        }
    }

    private var sports: [Sport] {
        if let sports = model.profile.sports, !sports.isEmpty { return sports }
        return Insights.trainingSports.filter { sport in model.workouts.contains { $0.sport == sport } }
    }

    private var goalText: String {
        guard let goal = model.profile.goal else { return String(localized: "Pas encore défini") }
        return [goal.title, goal.targetTime, goal.date.flatMap(Day.date).map(Day.short)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Header

    private var header: some View {
        let name = model.profile.name ?? String(localized: "Athlète")
        let vo2 = Insights.latestVO2(model.metrics)
        return VStack(spacing: DS.Spacing.xs) {
            DSAvatar(initials: String(name.split(separator: " ").compactMap(\.first).prefix(2)).uppercased(), size: 84)
            Text(name).font(.dsTitle)
            Text(model.profile.tagline ?? sports.map(\.label).joined(separator: " · ")).font(.dsCallout).foregroundStyle(.dsTextSecondary)
            HStack(spacing: DS.Spacing.l) {
                stat("\(Int(Insights.kmThisMonth(model.workouts).rounded())) km", String(localized: "ce mois"))
                stat(vo2.map { Fmt.number($0.value, decimals: 1) } ?? "–", String(localized: "VO2max"))
                stat("\(Insights.weekStreak(model.workouts))", String(localized: "semaines d'affilée"))
            }
            .padding(.top, DS.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Spacing.s)
        .studioComponent("En-tête profil")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.headline, design: .rounded))
            Text(label).font(.dsCaption).foregroundStyle(.dsTextSecondary)
        }
    }

    // MARK: Connections

    private var connections: some View {
        VStack(spacing: 0) {
            connectionRow(
                icon: AnyView(symbolIcon("heart.fill", .pink)),
                name: String(localized: "Apple Santé"),
                detail: model.healthAsked ? String(localized: "\(model.workouts.count) séances · synchro \(model.lastSync?.formatted(date: .omitted, time: .shortened) ?? "–")") : String(localized: "Non autorisé"),
                ok: model.healthAsked,
                action: model.healthAsked ? nil : RowAction(title: String(localized: "Autoriser"), run: requestHealth)
            )
            Divider()
            connectionRow(
                icon: AnyView(symbolIcon("applewatch", .black)),
                name: String(localized: "Apple Watch"),
                detail: watchDetail,
                ok: watchState == .authorized,
                action: nil
            )
            Divider()
            connectionRow(
                icon: AnyView(ClaudeMark().padding(6).frame(width: 36, height: 36).background(Color.claudeCream, in: RoundedRectangle(cornerRadius: 9, style: .continuous))),
                name: String(localized: "Claude"),
                detail: model.claude.isConnected ? String(localized: "Connecteur actif · dernière lecture \(model.claude.lastSeenAt.map(Fmt.time(isoString:)) ?? "–")") : String(localized: "Pas encore connecté"),
                ok: model.claude.isConnected,
                action: model.claude.isConnected ? nil : RowAction(title: String(localized: "Connecter"), run: openConnect)
            )
        }
        .dsCard(padding: DS.Spacing.s)
    }

    private var watchDetail: String {
        guard let watchState else { return String(localized: "Envoi des séances indisponible sur cet appareil") }
        switch watchState {
        case .authorized: return String(localized: "Les séances peuvent être envoyées sur ta montre")
        case .denied: return String(localized: "Accès refusé (Réglages › Confidentialité)")
        default: return String(localized: "Autorisation demandée au premier envoi")
        }
    }

    private func symbolIcon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private struct RowAction {
        let title: String
        let run: () -> Void
    }

    private func requestHealth() { Task { await model.requestHealthAccess() } }
    private func openConnect() { showConnect = true }

    private func connectionRow(icon: AnyView, name: String, detail: String, ok: Bool, action: RowAction?) -> some View {
        HStack(spacing: DS.Spacing.s) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.dsHeadline)
                Text(detail).font(.dsCaption).foregroundStyle(.dsTextSecondary)
            }
            Spacer()
            if let action {
                Button(action.title, action: action.run).font(.dsCallout.weight(.semibold))
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ok ? .green : .dsTextSecondary)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .studioComponent("Connexion · \(name)")
    }

    private func infoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: icon).foregroundStyle(.dsAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dsCaption).foregroundStyle(.dsTextSecondary)
                Text(value).font(.dsBody)
            }
            Spacer()
        }
        .padding(.vertical, DS.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
    }

    // MARK: Zones

    private var zones: some View {
        let ranges = HRZones.ranges(maxHr: model.maxHr)
        let shares = [0.64, 0.74, 0.82, 0.9, 1.0]
        return VStack(spacing: DS.Spacing.xs) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: DS.Spacing.s) {
                    Text("Z\(index + 1)")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 24)
                        .background(Color.dsZone(index + 1), in: RoundedRectangle(cornerRadius: 6))
                    Text(HRZones.names[index]).font(.dsCallout).frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.dsZone(index + 1).opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.dsZone(index + 1)).frame(width: geo.size.width * shares[index])
                            }
                    }
                    .frame(height: 6)
                    Text(ranges[index]).font(.dsCaption.monospacedDigit()).foregroundStyle(.dsTextSecondary)
                        .frame(width: 68, alignment: .trailing)
                }
            }
        }
        .dsCard(padding: DS.Spacing.s)
        .studioComponent("Zones FC")
    }
}
