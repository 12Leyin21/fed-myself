import SwiftUI
import CryptoKit

// Everything the Food Log screens need from their host app, in one file.
// Swap any of these for your own app's theme / networking — the screens only use what's here.

// MARK: - Where the server is

/// The server URL and token. Set them once (e.g. from a settings screen):
///   UserDefaults.standard.set("https://your-server.example", forKey: "foodLogURL")
///   UserDefaults.standard.set("your-token", forKey: "foodLogToken")
enum FoodLogConfig {
    static var baseURL: String {
        (UserDefaults.standard.string(forKey: "foodLogURL") ?? "http://localhost:8000")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var token: String { UserDefaults.standard.string(forKey: "foodLogToken") ?? "" }

    /// What the diary calls your AI in the UI ("小橘在估…", "AI 记的"). Set it in the diary's settings page.
    static var aiName: String {
        let n = (UserDefaults.standard.string(forKey: "foodLogAIName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "AI" : n
    }

    /// Upload raw JPEG bytes → server path like "/uploads/123-ab.jpg"
    static func uploadImage(_ data: Data, name: String) async -> String? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: baseURL + "/food/upload?name=\(encoded)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (resp, http) = try? await URLSession.shared.data(for: req),
              (http as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else { return nil }
        return json["url"] as? String
    }
}

// MARK: - Look

/// Accent colour lives here so you can re-theme the whole diary by injecting one object:
///   FoodDiaryView().environmentObject(AppTheme())
final class AppTheme: ObservableObject {
    @Published var accent: Color = Color(red: 0.85, green: 0.45, blue: 0.58)

    static let ink = Color(red: 0.16, green: 0.17, blue: 0.22)
    static let inkDim = Color(red: 0.36, green: 0.38, blue: 0.45)
    static let inkFaint = Color(red: 0.55, green: 0.57, blue: 0.63)
}

enum Fonts {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func serifItalic(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif).italic()
    }
}

/// The page background: a soft gradient. Replace with your wallpaper if you have one.
struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.98), Color(red: 0.84, green: 0.88, blue: 0.94)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

// MARK: - Images from the server (with the token, cached in memory + on disk)

struct AuthImageView: View {
    let urlPath: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, UIImage>()

    /// Put a just-uploaded image straight into the cache so it shows without a round trip.
    static func seed(urlPath: String, data: Data) {
        guard !urlPath.isEmpty, let image = UIImage(data: data) else { return }
        cache.setObject(image, forKey: urlPath as NSString)
        try? data.write(to: diskFile(urlPath), options: .atomic)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Color.white.opacity(0.3).overlay(Image(systemName: "photo").foregroundStyle(AppTheme.inkFaint))
            } else {
                Color.white.opacity(0.3).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: urlPath) { await load() }
    }

    private func load() async {
        failed = false
        if let hit = Self.cache.object(forKey: urlPath as NSString) { image = hit; return }
        let file = Self.diskFile(urlPath)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            Self.cache.setObject(img, forKey: urlPath as NSString)
            image = img
            return
        }
        let absolute = urlPath.hasPrefix("http") ? urlPath : FoodLogConfig.baseURL + urlPath
        guard let url = URL(string: absolute) else { failed = true; return }
        var req = URLRequest(url: url)
        // the token only ever goes to your own server, never to other hosts
        if absolute.hasPrefix(FoodLogConfig.baseURL) {
            req.setValue("Bearer \(FoodLogConfig.token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { failed = true; return }
        Self.cache.setObject(img, forKey: urlPath as NSString)
        try? data.write(to: file, options: .atomic)
        image = img
    }

    private static func diskFile(_ urlPath: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("food-log-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(urlPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(digest)
    }
}

extension UIImage {
    /// Shrink big photos before upload.
    func resizedIfNeeded(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

enum Radii {
    static let card: CGFloat = 24
}
