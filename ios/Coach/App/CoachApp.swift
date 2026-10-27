import SwiftUI

@main
struct CoachApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.dsAccent)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the Claude app: pick up what the coach just wrote.
                    if phase == .active, model.token != nil { Task { await model.refresh() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.onboarded {
            MainTabs()
        } else {
            ConnectClaudeView(mode: .onboarding)
        }
    }
}

enum Route: Hashable {
    case session(String)
    case workout(String)
    case records
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { Label("Aujourd'hui", systemImage: "sun.max") }
                .tag(AppModel.Tab.today)
            ProgramView()
                .tabItem { Label("Programme", systemImage: "calendar") }
                .tag(AppModel.Tab.program)
            ProgressScreen()
                .tabItem { Label("Progrès", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppModel.Tab.progress)
            ProfileView()
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
                .tag(AppModel.Tab.profile)
        }
    }
}

/// Destinations shared by every tab's NavigationStack.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .session(let id): SessionBriefView(sessionId: id)
        case .workout(let id): SessionDebriefView(workoutId: id)
        case .records: RecordsView()
        }
    }
}
