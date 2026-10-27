import UIKit

/// The coach lives in the Claude app (the athlete's own plan, via our MCP connector).
/// These helpers open Claude with a ready-to-send message.
enum ClaudeLink {
    /// claude.ai links open the Claude app when it's installed; `q` pre-fills the message.
    static func open(_ prompt: String) {
        var components = URLComponents(string: "https://claude.ai/new")!
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // Also on the clipboard, in case the prefill isn't honored.
        UIPasteboard.general.string = prompt
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    static func openApp() {
        UIApplication.shared.open(URL(string: "https://claude.ai/new")!)
    }

    // MARK: Prompts used across the app

    static let firstHello = String(localized: "Bonjour coach ! Je viens de connecter mon app Coach. Commence par get_athlete_overview, pose-moi les questions dont tu as besoin (objectif, disponibilités, blessures), puis construis mon programme avec upsert_sessions.")

    static func beforeSession(_ session: Session?) -> String {
        guard let session else { return String(localized: "Coach, j'ai une question avant ma séance du jour : ") }
        return String(localized: "Coach, une question avant ma séance « \(session.title) » (\(session.date), id \(session.id)) : ")
    }

    static func checkin(feeling: Int, session: Session?) -> String {
        let labels = ["", String(localized: "épuisé"), String(localized: "fatigué"), String(localized: "correct"), String(localized: "bien"), String(localized: "au top")]
        let base = String(localized: "Coach, je me sens \(labels[min(max(feeling, 1), 5)]) (\(feeling)/5) aujourd'hui.")
        guard let session else { return base + String(localized: " Qu'en penses-tu ?") }
        return base + String(localized: " Faut-il adapter ma séance « \(session.title) » (id \(session.id)) ?")
    }

    static func debrief(workoutId: String, title: String) -> String {
        String(localized: "Coach, débriefe ma séance « \(title) » : regarde get_workout avec l'id \(workoutId), puis écris l'analyse avec write_workout_analysis.")
    }

    static let editProgram = String(localized: "Coach, j'aimerais ajuster mon programme : ")
    static let progress = String(localized: "Coach, analyse mes progrès des dernières semaines (volume, VO2max, records) et dis-moi où j'en suis par rapport à mon objectif.")
    static let updateProfile = String(localized: "Coach, je voudrais mettre à jour mon profil (objectif, disponibilités, blessures) : ")
    static let dailyNote = String(localized: "Coach, fais-moi le point du jour (sommeil, VFC, séance prévue) et écris-le avec set_daily_note.")
}
