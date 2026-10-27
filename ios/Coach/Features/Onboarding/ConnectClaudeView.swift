import SwiftUI

/// Design: UI Studio "Connecter Claude" — header "Icônes reliées" with the Claude logo.
struct ConnectClaudeView: View {
    enum Mode { case onboarding, sheet }
    let mode: Mode

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var connected = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                VStack(spacing: DS.Spacing.s) {
                    healthStep
                    connectorStep
                    step(3, done: connected, title: String(localized: "Dis bonjour à ton coach"), detail: String(localized: "Il te posera quelques questions pour bâtir ton programme.")) { EmptyView() }
                }
                status
                VStack(spacing: DS.Spacing.s) {
                    CoachButton(title: String(localized: "Ouvrir Claude"), kind: connected ? .secondary : .primary) {
                        ClaudeLink.open(ClaudeLink.firstHello)
                    }
                    if connected {
                        Button(mode == .onboarding ? String(localized: "Continuer") : String(localized: "Terminé")) { finish() }
                            .buttonStyle(.dsPrimary)
                    } else {
                        Button("Plus tard") { finish() }
                            .buttonStyle(.dsGhost)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.l)
        }
        .background(Color.dsBackground)
        .task {
            // Wait for Claude's first call to the connector.
            while !Task.isCancelled {
                if await model.checkClaudeConnection() {
                    connected = true
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func finish() {
        model.onboarded = true
        if mode == .sheet { dismiss() }
        Task { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "figure.run")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.dsAccent.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.dsTextSecondary)
                ClaudeMark()
                    .padding(9)
                    .frame(width: 60, height: 60)
                    .background(Color.claudeCream, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.claudeCoral.opacity(0.25)))
            }
            Text("Connecte ton coach").font(.dsDisplay)
            Text("Ton coach, c'est Claude. Il lit tes données Santé et ton programme, et tu lui parles directement dans l'app Claude.")
                .font(.dsBody)
                .foregroundStyle(.dsTextSecondary)
        }
        .padding(.top, DS.Spacing.l)
    }

    private var healthStep: some View {
        step(1, done: model.healthAsked, title: model.healthAsked ? String(localized: "Apple Santé autorisé") : String(localized: "Autorise Apple Santé"), detail: String(localized: "Séances, fréquence cardiaque, sommeil, VFC")) {
            if !model.healthAsked {
                Button("Autoriser l'accès") { Task { await model.requestHealthAccess() } }
                    .buttonStyle(.dsSecondary)
                    .disabled(!HealthService.isAvailable)
            }
        }
    }

    private var connectorStep: some View {
        step(2, done: connected, title: String(localized: "Ajoute le connecteur dans Claude"), detail: String(localized: "Dans Claude : Paramètres › Connecteurs › Ajouter un connecteur personnalisé, puis colle cette adresse.")) {
            if let url = model.connectorURL {
                HStack {
                    Text(url)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = url
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundStyle(.dsAccent)
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .foregroundStyle(.dsAccent)
                }
                .padding(DS.Spacing.s)
                .background(Color.dsBackground, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(model.lastError ?? String(localized: "Connexion au serveur…")).font(.dsCaption).foregroundStyle(.dsTextSecondary)
                    Button("Réessayer") { Task { await model.bootstrap() } }.font(.dsCallout.weight(.semibold))
                }
            }
        }
    }

    private var status: some View {
        Group {
            if connected {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    VStack(alignment: .leading) {
                        Text("Claude est connecté").font(.dsHeadline)
                        Text(model.workouts.isEmpty ? String(localized: "Il peut lire tes données dès maintenant") : String(localized: "Il peut lire tes \(model.workouts.count) séances"))
                            .font(.dsCallout).foregroundStyle(.dsTextSecondary)
                    }
                    Spacer()
                }
                .padding(DS.Spacing.s)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            } else {
                HStack(spacing: DS.Spacing.s) {
                    ProgressView()
                    Text("En attente de la première connexion de Claude…")
                        .font(.dsCallout)
                        .foregroundStyle(.dsTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .studioComponent("Statut")
    }

    private func step<Extra: View>(_ number: Int, done: Bool, title: String, detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                } else {
                    Text("\(number)").font(.system(.callout, design: .rounded, weight: .bold))
                }
            }
            .foregroundStyle(done ? .white : .dsTextPrimary)
            .frame(width: 28, height: 28)
            .background(done ? Color.green : Color.dsBackground, in: Circle())
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title).font(.dsHeadline).strikethrough(done, color: .dsTextSecondary)
                Text(detail).font(.dsCallout).foregroundStyle(.dsTextSecondary)
                extra()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.s)
        .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
    }
}
