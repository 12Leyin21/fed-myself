import SwiftUI

/// Minimal host app: point it at your server, then show the diary.
/// In your own app you only need the files in ../FoodLog — drop this file.
@main
struct FoodLogExampleApp: App {
    @StateObject private var theme = AppTheme()

    init() {
        // ⚠️ put your own server and token here (or build a settings screen that writes these keys)
        if UserDefaults.standard.string(forKey: "foodLogURL") == nil {
            UserDefaults.standard.set("http://localhost:8000", forKey: "foodLogURL")
            UserDefaults.standard.set("change-me", forKey: "foodLogToken")
        }
    }

    var body: some Scene {
        WindowGroup {
            FoodDiaryView()
                .environmentObject(theme)
        }
    }
}
