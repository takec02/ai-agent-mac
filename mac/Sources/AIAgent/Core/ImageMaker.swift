import AppKit
import Foundation

/// 頼まれた絵を作る。作るのは別の Mac（社内の Mac Studio など）で、
/// このアプリは「作って」と頼んで、できた画像を受け取るだけ
@MainActor
enum ImageMaker {
    /// 保存先（作った絵は、あとから見返せるように残す）
    static let folder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AIエージェント/画像")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var isConfigured: Bool {
        !AppSettings.shared.imageServer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 絵を作ってもらい、保存したファイルの場所を返す
    @discardableResult
    static func make(prompt: String, size: Int = 1024, steps: Int = 20) async throws -> URL {
        let base = AppSettings.shared.imageServer.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, var components = URLComponents(string: base) else {
            throw Tools.ToolError(message: "画像を作る場所が決まっていません（設定 → AI の「画像生成」に、サーバーの URL を入れてください）")
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/generate" }
        guard let url = components.url else { throw Tools.ToolError(message: "サーバーの URL が正しくありません") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900  // 1枚に数分かかることがある
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = Keychain.get("imageServer"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "steps": steps, "width": size, "height": size,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Tools.ToolError(message: "画像を作る Mac につながりません（\(error.localizedDescription)）")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (HTTP.json(String(decoding: data, as: UTF8.self))?["error"] as? String)
                ?? "エラー \(http.statusCode)"
            throw Tools.ToolError(message: "画像を作れませんでした: \(message)")
        }
        guard let image = NSImage(data: data) else {
            throw Tools.ToolError(message: "受け取った画像を読めませんでした")
        }

        let name = Self.fileName(for: prompt)
        let saved = folder.appendingPathComponent(name)
        try data.write(to: saved)
        Camera.shared.show(image: image, label: "作った画像")
        Log.write("image generated: \(name)")
        return saved
    }

    /// 「夜空を見上げる青年」→「2026-09-28_1830_夜空を見上げる青年.png」
    private static func fileName(for prompt: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let words = prompt.prefix(20).replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stamp.string(from: Date()))_\(words).png"
    }
}
