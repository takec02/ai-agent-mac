import Foundation

/// 会話履歴。バックエンドを切り替えても引き継げるよう、テキストだけを保持する。
struct ChatMessage {
    let role: String  // "user" | "assistant"
    let content: String
    /// ローカル専用のツール（右筆のメールなど）を使ったやりとり。クラウドの AI には渡さない
    var localOnly = false
}

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 各バックエンドはテキストの断片を順に流す。ツール呼び出しのやりとりは内部で完結させる。
@MainActor
protocol LLMBackend {
    func respond(history: [ChatMessage], user: String, system: String) -> AsyncThrowingStream<String, Error>
}

let maxToolRounds = 5

@MainActor
func makeBackend(_ kind: BackendKind, settings: AppSettings) throws -> LLMBackend {
    let model = settings.model(for: kind)
    func key() throws -> String {
        guard let account = kind.keychainAccount, let k = Keychain.get(account), !k.isEmpty else {
            throw LLMError(message: "\(kind.shortLabel) の API キーが設定されていません（設定 → AI）")
        }
        return k
    }
    switch kind {
    case .local:
        return OllamaBackend(model: model)
    case .claude:
        return AnthropicBackend(model: model, apiKey: try key())
    case .gpt:
        return OpenAICompatBackend(model: model, apiKey: try key(), baseURL: "https://api.openai.com/v1")
    case .gemini:
        return OpenAICompatBackend(model: model, apiKey: try key(), baseURL: "https://generativelanguage.googleapis.com/v1beta/openai")
    }
}

// MARK: - HTTP ヘルパー

enum HTTP {
    /// よくある失敗を、何を直せばいいか分かるメッセージにする
    static func friendlyError(status: Int, body: String, model: String?) -> String {
        let b = body.lowercased()
        let modelName = model.map { "「\($0)」" } ?? ""
        switch status {
        case 401, 403:
            return "API キーが無効か、権限がありません。設定 → AI でキーを確認してください（HTTP \(status)）"
        case 404 where b.contains("model"), 400 where b.contains("model") && (b.contains("not") || b.contains("deprecat") || b.contains("invalid") || b.contains("retired")):
            return "モデル\(modelName)が使えません。提供が終了した可能性があります。設定 → AI でモデル名を新しいものに変えてください"
        case 400 where b.contains("web_search") || b.contains("tool") && b.contains("type"):
            return "AI のツール（Web 検索など）の仕様が変わった可能性があります。アプリの更新が必要です（HTTP 400）"
        case 429:
            return "利用上限に達しました。しばらく待つか、利用プランを確認してください（HTTP 429）"
        case 500...599:
            return "AI サービス側で一時的な障害が起きています。時間をおいて試してください（HTTP \(status)）"
        default:
            return "HTTP \(status): \(body.prefix(300))"
        }
    }

    static func postLines(_ url: String, headers: [String: String], body: [String: Any]) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        // 議事録の要約など、長い入力では最初の1文字まで時間がかかる（ローカル AI では数分）
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw LLMError(message: friendlyError(status: http.statusCode, body: text, model: body["model"] as? String))
        }
        return bytes.lines
    }

    static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// SSE の "data: {...}" 行から JSON を取り出す
    static func sseData(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        return json(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
}

@MainActor private func openAIStyleTools(local: Bool, query: String? = nil) -> [[String: Any]] {
    Tools.specs(local: local, query: query).map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
}

/// カメラの道具で撮った写真を、道具の結果と一緒に AI へ渡す
@MainActor
enum CameraAttachment {
    static func take(after toolName: String) -> Data? {
        ["look_camera", "look_image"].contains(toolName) ? Camera.shared.takePendingJPEG() : nil
    }

    /// カメラで撮ることを頼んでいる発話か（「天気を見て」のような、カメラと関係ない「見て」は含めない）
    static func isCameraRequest(_ text: String) -> Bool {
        let patterns = [
            "撮って", "撮り直", "撮影", "カメラ", "写真", "QR", "ＱＲ", "バーコード", "名刺",
            "これ(は)?(何|なに|なん)", "(何|なに|なん)これ", "これ(って)?(何|なに|なん)", "これ(を)?(読|見)", "これ見",
            "(これ|この人|この方|こいつ)(を)?(登録|追加|入れ|保存)", "連絡先に(登録|追加|入れ)", "アドレス帳に(登録|追加|入れ)",
            "もう一(回|度|かい)(見|撮|読)", "もう(いっ|一)かい(見|撮|読)",
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static let blindNote = "（今の AI は画像を見られないため、写真そのものは渡していません。上の文字とコードだけで答え、見た目の説明が必要なら、画像を読めるモデルか Claude などに切り替えると見られると伝えてください）"

    /// 画像を読めないモデル向けに、Mac の中の画像対応モデルに写真を説明してもらって文章として渡す
    static func describedResult(_ result: String, jpeg: Data) async -> String {
        AgentController.shared.showNote("写真を見ています…")
        defer { AgentController.shared.showNote("") }
        guard let description = await VisionDescriber.describe(jpeg) else { return result + "\n" + blindNote }
        return result + "\n写っているもの（Mac の中の画像対応モデルによる説明）:\n" + description
    }
}

// MARK: - Ollama (ローカル)

struct OllamaBackend: LLMBackend {
    let model: String
    var host = "http://localhost:11434"

    /// 画像を読めるモデルか（Ollama がモデルの機能として "vision" を返すか）
    private func canSeeImages() async -> Bool { await VisionDescriber.canSeeImages(model) }

    func respond(history: [ChatMessage], user: String, system: String) -> AsyncThrowingStream<String, Error> {
        // 「それを要約して」のような続きの質問にも対応できるよう、直前の質問も話題の判断に含める
        let lastUser = history.last { $0.role == "user" }?.content ?? ""
        let topicQuery = user + " " + lastUser
        return AsyncThrowingStream { cont in
            let task = Task { @MainActor in
                do {
                    var messages: [[String: Any]] = [["role": "system", "content": system]]
                    messages += history.map { ["role": $0.role, "content": $0.content] }
                    messages.append(["role": "user", "content": user])
                    // 小さいモデルは「撮り直して」と言われても道具を呼ばず、前の答えを使い回すことがある。
                    // カメラを頼む言葉があれば、モデルの判断を待たずに先に撮って、その結果を渡す
                    // 画像を渡されているとき、またはカメラを頼まれたときは、モデルの判断を待たずに先に見る
                    let firstLook = Camera.shared.hasAttachment ? "look_image"
                        : (CameraAttachment.isCameraRequest(user) ? "look_camera" : nil)
                    if let firstLook {
                        let (result, _) = await Tools.execute(name: firstLook, arguments: [String: Any]())
                        messages.append(["role": "assistant", "content": "",
                                         "tool_calls": [["function": ["name": firstLook, "arguments": [String: Any]()]]]])
                        var message: [String: Any] = ["role": "tool", "content": result, "tool_name": firstLook]
                        if let jpeg = CameraAttachment.take(after: firstLook) {
                            if await canSeeImages() {
                                message["images"] = [jpeg.base64EncodedString()]
                            } else {
                                message["content"] = await CameraAttachment.describedResult(result, jpeg: jpeg)
                            }
                        }
                        messages.append(message)
                    }
                    for _ in 0..<maxToolRounds {
                        let body: [String: Any] = [
                            "model": model, "messages": messages, "tools": openAIStyleTools(local: true, query: topicQuery),
                            "stream": true, "think": false, "keep_alive": "30m",
                            // 既定の 4096 では、写真や長い会話ですぐ足りなくなる
                            "options": ["num_ctx": AppSettings.shared.ollamaContext],
                        ]
                        let lines: AsyncLineSequence<URLSession.AsyncBytes>
                        do {
                            lines = try await HTTP.postLines("\(host)/api/chat", headers: [:], body: body)
                        } catch let e as URLError where e.code == .cannotConnectToHost {
                            throw LLMError(message: "Ollama に接続できません。Ollama を起動してください")
                        }
                        var text = ""
                        var calls: [[String: Any]] = []
                        for try await line in lines {
                            guard let obj = HTTP.json(line) else { continue }
                            if let err = obj["error"] as? String {
                                throw LLMError(message: err.contains("exceed_context_size")
                                    ? "会話が長くなりすぎました（写真は多くの量を使います）。ゴミ箱ボタンで会話を消すか、設定 → AI で「一度に扱える量」を広げてください"
                                    : err)
                            }
                            let msg = obj["message"] as? [String: Any] ?? [:]
                            if let c = msg["content"] as? String, !c.isEmpty {
                                text += c
                                cont.yield(c)
                            }
                            if let tc = msg["tool_calls"] as? [[String: Any]] { calls += tc }
                        }
                        if calls.isEmpty { break }
                        messages.append(["role": "assistant", "content": text, "tool_calls": calls])
                        for call in calls {
                            let fn = call["function"] as? [String: Any] ?? [:]
                            let name = fn["name"] as? String ?? ""
                            let (result, _) = await Tools.execute(name: name, arguments: fn["arguments"])
                            var message: [String: Any] = ["role": "tool", "content": result, "tool_name": name]
                            if let jpeg = CameraAttachment.take(after: name) {
                                if await canSeeImages() {
                                    message["images"] = [jpeg.base64EncodedString()]
                                } else {
                                    message["content"] = await CameraAttachment.describedResult(result, jpeg: jpeg)
                                }
                            }
                            messages.append(message)
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Claude (Anthropic Messages API)

/// Swift 公式 SDK がないため Messages API を HTTP で直接呼ぶ。
struct AnthropicBackend: LLMBackend {
    let model: String
    let apiKey: String
    var effort = "low"

    func respond(history: [ChatMessage], user: String, system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor in
                do {
                    var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.content] }
                    messages.append(["role": "user", "content": user])
                    var tools: [[String: Any]] = Tools.specs(local: false, tavily: false).map {
                        ["name": $0.name, "description": $0.description, "input_schema": $0.parameters, "eager_input_streaming": true]
                    }
                    // Claude 内蔵の Web 検索（Anthropic のサーバー側で検索して結果を読む）
                    tools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 5,
                                  "user_location": ["type": "approximate", "country": "JP", "timezone": "Asia/Tokyo"]])
                    let headers = [
                        "x-api-key": apiKey,
                        "anthropic-version": "2023-06-01",
                        "anthropic-beta": "server-side-fallback-2026-07-01",
                    ]
                    for _ in 0..<maxToolRounds {
                        let body: [String: Any] = [
                            "model": model, "max_tokens": 8000, "stream": true,
                            "system": system + "\n- Latency-sensitive; begin your visible answer immediately.",
                            "tools": tools, "messages": messages,
                            "output_config": ["effort": effort],
                            "fallbacks": "default",
                        ]
                        let lines = try await HTTP.postLines("https://api.anthropic.com/v1/messages", headers: headers, body: body)

                        // ストリームから content ブロックを組み立てる（thinking ブロック等も次の往復でそのまま返す必要がある）
                        var blocks: [Int: [String: Any]] = [:]
                        var partialJSON: [Int: String] = [:]
                        var stopReason = ""
                        for try await line in lines {
                            guard let ev = HTTP.sseData(line), let type = ev["type"] as? String else { continue }
                            let index = ev["index"] as? Int ?? 0
                            switch type {
                            case "content_block_start":
                                blocks[index] = ev["content_block"] as? [String: Any] ?? [:]
                            case "content_block_delta":
                                let delta = ev["delta"] as? [String: Any] ?? [:]
                                var block = blocks[index] ?? [:]
                                switch delta["type"] as? String {
                                case "text_delta":
                                    let t = delta["text"] as? String ?? ""
                                    block["text"] = (block["text"] as? String ?? "") + t
                                    cont.yield(t)
                                case "thinking_delta":
                                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                                case "signature_delta":
                                    block["signature"] = delta["signature"]
                                case "input_json_delta":
                                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                                default:
                                    break
                                }
                                blocks[index] = block
                            case "content_block_stop":
                                if ["tool_use", "server_tool_use"].contains(blocks[index]?["type"] as? String) {
                                    let raw = partialJSON[index] ?? ""
                                    blocks[index]?["input"] = raw.isEmpty ? [String: Any]() : (HTTP.json(raw) ?? ["_invalid_json": raw])
                                }
                            case "message_delta":
                                if let d = ev["delta"] as? [String: Any], let r = d["stop_reason"] as? String { stopReason = r }
                            case "error":
                                let e = ev["error"] as? [String: Any]
                                throw LLMError(message: e?["message"] as? String ?? "API error")
                            default:
                                break
                            }
                        }
                        let content = blocks.keys.sorted().compactMap { blocks[$0] }

                        if stopReason == "refusal" {
                            cont.yield("申し訳ありません、その依頼にはお応えできません。")
                            break
                        }
                        if stopReason == "pause_turn" {
                            messages.append(["role": "assistant", "content": content])
                            continue
                        }
                        let toolUses = content.filter { $0["type"] as? String == "tool_use" }
                        if toolUses.isEmpty { break }
                        if stopReason == "max_tokens" {
                            cont.yield("応答が長くなりすぎたため中断しました。")
                            break
                        }
                        messages.append(["role": "assistant", "content": content])
                        var results: [[String: Any]] = []
                        for use in toolUses {
                            let id = use["id"] as? String ?? ""
                            let input = use["input"] as? [String: Any] ?? [:]
                            let (result, isError): (String, Bool)
                            if let bad = input["_invalid_json"] {
                                (result, isError) = ("INVALID_JSON: \(bad)", true)
                            } else {
                                // eager streaming では API 側で入力が検証されないので Tools 側で型を検証する
                                (result, isError) = await Tools.execute(name: use["name"] as? String ?? "", arguments: input)
                            }
                            if let jpeg = CameraAttachment.take(after: use["name"] as? String ?? "") {
                                results.append(["type": "tool_result", "tool_use_id": id, "is_error": isError, "content": [
                                    ["type": "text", "text": result],
                                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                                ]])
                            } else {
                                results.append(["type": "tool_result", "tool_use_id": id, "content": result, "is_error": isError])
                            }
                        }
                        messages.append(["role": "user", "content": results])
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI 互換 (GPT / Gemini / Groq など)

struct OpenAICompatBackend: LLMBackend {
    let model: String
    let apiKey: String
    let baseURL: String

    func respond(history: [ChatMessage], user: String, system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor in
                do {
                    var messages: [[String: Any]] = [["role": "system", "content": system]]
                    messages += history.map { ["role": $0.role, "content": $0.content] }
                    messages.append(["role": "user", "content": user])
                    for _ in 0..<maxToolRounds {
                        let body: [String: Any] = ["model": model, "messages": messages, "tools": openAIStyleTools(local: false), "stream": true]
                        let lines = try await HTTP.postLines("\(baseURL)/chat/completions", headers: ["Authorization": "Bearer \(apiKey)"], body: body)
                        var text = ""
                        var calls: [Int: (id: String, name: String, args: String)] = [:]
                        for try await line in lines {
                            guard let obj = HTTP.sseData(line),
                                  let choice = (obj["choices"] as? [[String: Any]])?.first,
                                  let delta = choice["delta"] as? [String: Any] else { continue }
                            if let c = delta["content"] as? String, !c.isEmpty {
                                text += c
                                cont.yield(c)
                            }
                            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let i = tc["index"] as? Int ?? 0
                                var cur = calls[i] ?? ("", "", "")
                                if let id = tc["id"] as? String { cur.id = id }
                                if let fn = tc["function"] as? [String: Any] {
                                    cur.name += fn["name"] as? String ?? ""
                                    cur.args += fn["arguments"] as? String ?? ""
                                }
                                calls[i] = cur
                            }
                        }
                        if calls.isEmpty { break }
                        let ordered = calls.keys.sorted().compactMap { calls[$0] }
                        messages.append([
                            "role": "assistant",
                            "content": text.isEmpty ? NSNull() : text,
                            "tool_calls": ordered.map {
                                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.args.isEmpty ? "{}" : $0.args]]
                            },
                        ])
                        var photos: [Data] = []
                        for c in ordered {
                            let (result, _) = await Tools.execute(name: c.name, arguments: c.args)
                            messages.append(["role": "tool", "tool_call_id": c.id, "content": result])
                            if let jpeg = CameraAttachment.take(after: c.name) { photos.append(jpeg) }
                        }
                        // 道具の結果には画像を入れられないので、撮った写真は続けて利用者の発言として渡す
                        if !photos.isEmpty {
                            messages.append(["role": "user", "content": [["type": "text", "text": "（カメラで撮った写真）"]] + photos.map {
                                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
                            }])
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
