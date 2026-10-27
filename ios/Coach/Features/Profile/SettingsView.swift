import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverText = ""
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let url = model.connectorURL {
                        Text(url).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        Button("Copier l'adresse", systemImage: "doc.on.doc") { UIPasteboard.general.string = url }
                        ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
                    }
                    Button("Ouvrir Claude", systemImage: "sparkles") { ClaudeLink.openApp() }
                } header: {
                    Text("Connecteur Claude")
                } footer: {
                    Text("À ajouter dans Claude : Paramètres › Connecteurs › Ajouter un connecteur personnalisé. Garde cette adresse secrète : elle donne accès à tes données.")
                }

                Section {
                    Button { Task { await model.refresh() } } label: {
                        HStack {
                            Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                            if model.isRefreshing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isRefreshing)
                    if let sync = model.lastSync {
                        LabeledContent("Dernière synchro", value: sync.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Séances Apple Santé", value: "\(model.workouts.count)")
                } header: {
                    Text("Données")
                }

                Section {
                    TextField("URL du serveur", text: $serverText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Appliquer") {
                        if let url = URL(string: serverText.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
                            model.serverURL = url
                            model.resetAccount()
                            dismiss()
                            Task { await model.bootstrap() }
                        }
                    }
                    .disabled(serverText == model.serverURL.absoluteString)
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("Changer de serveur crée un nouveau compte et un nouveau connecteur.")
                }

                #if DEBUG
                Section("Développement") {
                    Button {
                        Task { await model.seedDemoData() }
                    } label: {
                        HStack {
                            Label("Générer des données de démo (Apple Santé)", systemImage: "wand.and.stars")
                            if model.isSeeding { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.isSeeding)
                    Button("Revoir l'écran de connexion", systemImage: "arrow.uturn.backward") {
                        model.onboarded = false
                        dismiss()
                    }
                }
                #endif

                Section {
                    Button("Réinitialiser le compte", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .onAppear { serverText = model.serverURL.absoluteString }
            .confirmationDialog("Réinitialiser ?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Réinitialiser", role: .destructive) {
                    model.resetAccount()
                    dismiss()
                    Task { await model.bootstrap() }
                }
            } message: {
                Text("Un nouveau compte et un nouveau connecteur seront créés. Il faudra reconnecter Claude.")
            }
        }
    }
}
