import Foundation

/// 道具を付けずに、選んでいる AI に1回だけ聞く（提案書の下書きなど、決まった形の文を作らせるとき用）。
/// 道具を渡すと、小さいモデルは頼んでいない道具を使い始めることがあるので分けている
@MainActor
enum PlainLLM {
    static func ask(system: String, user: String, json: Bool = false) async throws -> String {
        let s = AppSettings.shared
        let kind = s.backend
        let model = s.model(for: kind)
        func key() throws -> String {
            guard let account = kind.keychainAccount, let k = Keychain.get(account), !k.isEmpty else {
                throw LLMError(message: "\(kind.shortLabel) の API キーが設定されていません（設定 → AI）")
            }
            return k
        }
        switch kind {
        case .local:
            var body: [String: Any] = [
                "model": model, "stream": false, "think": false, "keep_alive": "30m",
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "options": ["temperature": 0.4, "num_ctx": s.ollamaContext],
            ]
            if json { body["format"] = "json" }
            let obj = try await post("http://localhost:11434/api/chat", headers: [:], body: body, model: model)
            return (obj["message"] as? [String: Any])?["content"] as? String ?? ""
        case .claude:
            let body: [String: Any] = [
                "model": model, "max_tokens": 8000, "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            let obj = try await post("https://api.anthropic.com/v1/messages",
                                     headers: ["x-api-key": try key(), "anthropic-version": "2023-06-01"], body: body, model: model)
            return (obj["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        case .gpt, .gemini:
            let base = kind == .gpt ? "https://api.openai.com/v1" : "https://generativelanguage.googleapis.com/v1beta/openai"
            var body: [String: Any] = [
                "model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            if json { body["response_format"] = ["type": "json_object"] }
            let obj = try await post("\(base)/chat/completions", headers: ["Authorization": "Bearer \(try key())"], body: body, model: model)
            let choice = (obj["choices"] as? [[String: Any]])?.first
            return (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        }
    }

    /// 返ってきた文から JSON の部分だけを取り出して読む（前後に説明やコードの囲みが付くことがある）
    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return HTTP.json(String(text[start...end]))
    }

    private static func post(_ url: String, headers: [String: String], body: [String: Any], model: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600  // 長い会議を読ませると時間がかかる
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError(message: HTTP.friendlyError(status: http.statusCode, body: text, model: model))
        }
        return HTTP.json(text) ?? [:]
    }
}
