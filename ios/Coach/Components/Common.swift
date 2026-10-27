import SwiftUI

/// Section title with an optional tappable action on the right.
struct SectionHeader: View {
    let title: String
    var action: String?
    var onTap: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.dsHeadline)
            Spacer()
            if let action {
                if let onTap {
                    Button(action, action: onTap).font(.dsCallout).foregroundStyle(.dsAccent)
                } else {
                    Text(action).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                }
            }
        }
        .studioComponent("En-tête · \(title)")
    }
}

struct EmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label(title, systemImage: icon).font(.dsHeadline)
            Text(message).font(.dsCallout).foregroundStyle(.dsTextSecondary)
            if let buttonTitle, let action {
                CoachButton(title: buttonTitle, kind: .secondary, action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.lastError {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Synchronisation impossible").font(.dsCallout.weight(.semibold))
                    Text(error).font(.dsCaption).foregroundStyle(.dsTextSecondary).lineLimit(3)
                }
                Spacer()
                Button("Réessayer") { Task { await model.refresh() } }
                    .font(.dsCallout.weight(.semibold))
            }
            .padding(DS.Spacing.s)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
    }
}

/// Numbered list of a session's steps (the "Étapes" design).
struct StepsList: View {
    let steps: [Step]
    let sport: Sport

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    VStack(spacing: 0) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.dsZone(step.zone), in: Circle())
                        if index < steps.count - 1 {
                            Rectangle().fill(Color.dsBorder).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(step.name).font(.dsHeadline)
                            Spacer()
                            Text(StepText.amount(step, sport: sport)).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                        }
                        Text(StepText.detail(step, sport: sport)).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                    }
                    .padding(.bottom, DS.Spacing.m)
                }
                .studioComponent("Étape · \(step.name)")
            }
        }
        .dsCard()
    }
}

enum StepText {
    static func amount(_ step: Step, sport: Sport) -> String {
        let one: String
        if let d = step.distanceM {
            one = d >= 1000 && sport != .natation ? "\(Fmt.km(d)) km" : "\(Int(d)) m"
        } else if let seconds = step.seconds {
            one = Fmt.duration(seconds: seconds)
        } else {
            one = ""
        }
        return step.repeatCount > 1 ? "\(step.repeatCount) × \(one)" : one
    }

    static func detail(_ step: Step, sport: Sport) -> String {
        var parts: [String] = []
        if let detail = step.detail, !detail.isEmpty { parts.append(detail) }
        if let pace = step.target?.paceSecPerKm { parts.append("\(Fmt.pace(pace)) /km") }
        if let swim = step.target?.swimPaceSecPer100m { parts.append("\(Fmt.pace(swim)) /100 m") }
        if let speed = step.target?.speedKmh { parts.append("\(Fmt.number(speed, decimals: 1)) km/h") }
        if let low = step.target?.hrMin, let high = step.target?.hrMax { parts.append(String(localized: "FC \(low)–\(high)")) }
        parts.append("Z\(step.zone)")
        if let recovery = step.recovery, step.repeatCount > 1 {
            let amount = recovery.distanceM.map { "\(Int($0)) m" } ?? recovery.seconds.map { Fmt.duration(seconds: $0) } ?? ""
            parts.append(String(localized: "récup \(amount)"))
        }
        return parts.joined(separator: " · ")
    }
}
