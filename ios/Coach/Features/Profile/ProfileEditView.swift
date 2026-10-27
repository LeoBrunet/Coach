import SwiftUI

/// "Modifier" on the profile: what the coach uses to plan (goal, availability, injuries, sports, max HR).
struct ProfileEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var goalTitle = ""
    @State private var hasGoalDate = false
    @State private var goalDate = Date()
    @State private var goalTime = ""
    @State private var availability = ""
    @State private var injuries = ""
    @State private var sports: Set<Sport> = []
    @State private var maxHr = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Toi") {
                    TextField("Prénom", text: $name)
                }
                Section("Objectif") {
                    TextField("Ex. Semi-marathon de Paris", text: $goalTitle)
                    Toggle("Date de l'épreuve", isOn: $hasGoalDate)
                    if hasGoalDate {
                        DatePicker("Date", selection: $goalDate, displayedComponents: .date)
                    }
                    TextField("Temps visé (ex. 1 h 45)", text: $goalTime)
                }
                Section("Disponibilités") {
                    TextField("Ex. 5 séances / sem., sortie longue le dimanche", text: $availability, axis: .vertical)
                }
                Section("Points d'attention") {
                    TextField("Blessures, douleurs…", text: $injuries, axis: .vertical)
                }
                Section("Sports") {
                    ForEach(Insights.trainingSports) { sport in
                        Toggle(isOn: Binding(get: { sports.contains(sport) }, set: { if $0 { sports.insert(sport) } else { sports.remove(sport) } })) {
                            Label(sport.label, systemImage: sport.icon)
                        }
                    }
                }
                Section {
                    TextField("FC max (bpm)", text: $maxHr).keyboardType(.numberPad)
                } header: {
                    Text("Fréquence cardiaque")
                } footer: {
                    Text("Laisse vide pour utiliser la FC max observée sur tes séances (\(model.maxHr) bpm).")
                }
            }
            .navigationTitle("Mon profil sportif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled(saving)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let profile = model.profile
        name = profile.name ?? ""
        goalTitle = profile.goal?.title ?? ""
        if let date = profile.goal?.date.flatMap(Day.date) {
            hasGoalDate = true
            goalDate = date
        }
        goalTime = profile.goal?.targetTime ?? ""
        availability = profile.availability ?? ""
        injuries = profile.injuries ?? ""
        sports = Set(profile.sports ?? [])
        maxHr = profile.maxHr.map(String.init) ?? ""
    }

    private func save() {
        saving = true
        var profile = Profile()
        let trimmed = { (s: String) -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        profile.name = trimmed(name)
        if let title = trimmed(goalTitle) {
            profile.goal = Goal(title: title, date: hasGoalDate ? Day.string(goalDate) : nil, targetTime: trimmed(goalTime))
        }
        profile.availability = trimmed(availability)
        profile.injuries = trimmed(injuries)
        profile.sports = Insights.trainingSports.filter(sports.contains)
        profile.maxHr = Int(maxHr)
        Task {
            if await model.saveProfile(profile) { dismiss() }
            saving = false
        }
    }
}
