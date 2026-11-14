import Foundation

/// 作った PowerPoint を自分の Google ドライブに上げ、Google スライドに変換する。
/// ログイン情報は、個人の Google 連携（workspace-mcp）が Mac の中に保存したものを読むだけで、書き換えない
@MainActor
enum GoogleDriveUpload {
    private static let credentials = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".google_workspace_mcp/credentials")

    static func asSlides(_ file: URL, name: String) async throws -> URL {
        let token = try await accessToken()
        let boundary = "aiagent-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": "application/vnd.google-apps.presentation",
        ])
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        add("\r\n--\(boundary)\r\nContent-Type: application/vnd.openxmlformats-officedocument.presentationml.presentation\r\n\r\n")
        body.append(try Data(contentsOf: file))
        add("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let obj = HTTP.json(String(decoding: data, as: UTF8.self)) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let link = obj["webViewLink"] as? String, let url = URL(string: link) else {
            Log.write("drive upload failed: \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw Tools.ToolError(message: "Google ドライブに上げられませんでした。PowerPoint はできているので、それを使ってください: \(file.lastPathComponent)")
        }
        Log.write("drive upload: slides created")
        return url
    }

    /// 保存されているログイン情報から、使える合い鍵（アクセストークン）を取り出す。期限切れなら取り直す
    private static func accessToken() async throws -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: credentials, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.pathExtension == "json" && $0.lastPathComponent != "oauth_states.json" }),
              let saved = HTTP.json(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)) else {
            throw Tools.ToolError(message: "個人の Google にログインしていません（設定 → 連携）")
        }
        let scopes = saved["scopes"] as? [String] ?? []
        guard scopes.contains("https://www.googleapis.com/auth/drive") || scopes.contains("https://www.googleapis.com/auth/drive.file") else {
            throw Tools.ToolError(message: "Google ドライブに書き込む許可がありません（設定 → 連携 で、ドライブの書き込みを許可してログインし直してください）")
        }
        // まだ期限内なら、そのまま使う（期限は世界標準時で書かれている）
        if let token = saved["token"] as? String, let expiry = saved["expiry"] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            if let date = f.date(from: expiry), date.timeIntervalSinceNow > 60 { return token }
        }
        guard let refresh = saved["refresh_token"] as? String, let clientID = saved["client_id"] as? String,
              let secret = saved["client_secret"] as? String else {
            throw Tools.ToolError(message: "Google のログイン情報が足りません。ログインし直してください")
        }
        var request = URLRequest(url: URL(string: saved["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refresh),
            .init(name: "client_id", value: clientID), .init(name: "client_secret", value: secret),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let token = HTTP.json(String(decoding: data, as: UTF8.self))?["access_token"] as? String else {
            throw Tools.ToolError(message: "Google のログインが切れています。サスケに予定やメールを頼むとログインのページが開くので、ログインし直してください")
        }
        return token
    }
}
