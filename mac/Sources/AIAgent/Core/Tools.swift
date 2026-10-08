import AppKit
import Foundation

/// AI が呼び出せる Mac 操作ツール。スキーマは共通の JSON Schema で定義し、各バックエンドで形式を変換する。
/// 音声の聞き間違いで危険な操作をしないよう、任意のシェルコマンドを実行するツールは用意していない。
struct ToolSpec {
    let name: String
    let description: String
    /// 引数の JSON Schema
    let parameters: [String: Any]
    /// 組み込みツールの引数定義（MCP ツールでは空）
    let properties: [String: [String: Any]]

    init(name: String, description: String, properties: [String: [String: Any]]) {
        self.name = name
        self.description = description
        self.properties = properties
        parameters = ["type": "object", "properties": properties, "required": Array(properties.keys)]
    }

    init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        properties = [:]
        parameters = schema
    }
}

@MainActor
enum Tools {
    /// AI に渡すツール（組み込み＋接続中の MCP サーバーのツール）
    /// - local: AI がローカル（Ollama）か。クラウドの AI にはローカル専用の MCP ツールを渡さない
    /// - tavily: Tavily の検索を含めるか（Claude は内蔵の Web 検索を使うので含めない）
    /// - query: 渡すと、外部サービスのツールを質問に関係するものだけに絞る（ローカル AI は道具が多いと使わなくなるため）
    static func specs(local: Bool, tavily: Bool = true, query: String? = nil) -> [ToolSpec] {
        builtin.filter { tavily || $0.name != "search_web" } + MCPManager.shared.toolSpecs(includeLocalOnly: local, query: query)
    }

    /// 動作確認用：すべてのツール
    static var allSpecs: [ToolSpec] { specs(local: true) }

    static let builtin: [ToolSpec] = [
        ToolSpec(name: "get_datetime", description: "現在の日付と時刻を取得する", properties: [:]),
        ToolSpec(name: "open_app", description: "Mac のアプリを起動する。name はアプリ名（例: Safari, Music, Finder, カレンダー）",
                 properties: ["name": ["type": "string"]]),
        ToolSpec(name: "set_volume", description: "Mac の出力音量を 0〜100 で設定する",
                 properties: ["level": ["type": "integer", "minimum": 0, "maximum": 100]]),
        ToolSpec(name: "get_battery", description: "バッテリー残量と充電状態を取得する", properties: [:]),
        ToolSpec(name: "music_control",
                 description: "音楽（ミュージック.app）の再生操作。例:「音楽かけて」→play、「止めて」→pause、「次の曲」「スキップ」→next、「前の曲」→previous",
                 properties: ["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]]]),
        ToolSpec(name: "search_web",
                 description: "インターネットで検索し、上位の結果（タイトル・URL・抜粋）と要約を返す。最新の情報、ニュース、店・イベント・人物など、知識だけでは確かでないことを調べるときに使う。必要なら続けて read_webpage で本文を読む",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "read_webpage", description: "指定した URL の Web ページの本文を読む（最大8000文字）",
                 properties: ["url": ["type": "string"]]),
        ToolSpec(name: "open_web_search", description: "ブラウザで検索結果のページを開く（ユーザーが画面で自分で見たいと言ったとき用。内容は読み上げられない）",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "get_weather",
                 description: "日本の天気予報（今日・明日の天気、降水確率、予想気温）を気象庁のデータで取得する。place は都道府県・地方・市区町村名（例: 東京、大阪府、札幌市、横浜）",
                 properties: ["place": ["type": "string"]]),
        ToolSpec(name: "open_weathernews", description: "ウェザーニュースの天気ページをブラウザで開く（ユーザーがウェザーニュースで見たいと言ったとき）。place は地名",
                 properties: ["place": ["type": "string"]]),
        ToolSpec(name: "calculate",
                 description: "計算をする。割引・税込み・合計・平均・割り算・単位換算など、数値の計算は暗算せず必ずこれを使う。expression は数式（Python と同じ書き方。例: 12800*0.7*1.1、round(1234/7, 2)、sqrt(2)、sum([120, 340, 560])）",
                 properties: ["expression": ["type": "string"]]),
        ToolSpec(name: "remember",
                 description: "長く覚えておくことを記録する。ユーザーが「覚えておいて」と言ったとき、および会話で分かった人・好み・決めごと（例: 山田さんは取引先、返信は丁寧めに）を次回以降も使いたいときに呼ぶ。text は短い一文",
                 properties: ["text": ["type": "string"]]),
        ToolSpec(name: "recall", description: "覚えていることを言葉で探す。query に探したい言葉（空文字ならすべて）",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "forget", description: "覚えていることを消す。query に含まれる言葉で探して消す。消す前にユーザーへ確認する",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "look_camera",
                 description: "Mac のカメラで今見えているものを1枚撮って見る。「これ何？」「これ読んで」「この名刺を登録して」「QR コード読んで」など、ユーザーがカメラに何かを見せているときに使う。写っている文字と QR コード・バーコードの中身を返す",
                 properties: [:]),
        ToolSpec(name: "search_documents",
                 description: "登録した資料（PDF・Word・PowerPoint・Excel・テキストなど）の中から、質問に関係する箇所を探す。資料の内容について聞かれたら、答える前に必ずこれを使う。query は探したい言葉",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "list_documents", description: "登録されている資料の一覧を返す", properties: [:]),
        ToolSpec(name: "add_mcp_server",
                 description: "外部サービスの MCP サーバーを登録して使えるようにする。「このMCPを登録して」とURLを渡されたら使う。name は英数字の短い名前（例: openpoi）、url は MCP の接続先（https で終わりが /mcp のことが多い）、token は必要なときだけ。登録前に確認する",
                 properties: ["name": ["type": "string"], "url": ["type": "string"], "token": ["type": "string", "optional": true]]),
        ToolSpec(name: "list_mcp_servers", description: "今つながっている外部サービス（MCP サーバー）の一覧と状態を返す", properties: [:]),
        ToolSpec(name: "remove_mcp_server", description: "登録した MCP サーバーを外す。name は登録名。外す前に確認する",
                 properties: ["name": ["type": "string"]]),
        ToolSpec(name: "generate_image",
                 description: "頼まれた絵を作る。「〇〇の絵を描いて」「画像を作って」と言われたら使う。prompt は作ってほしい内容を具体的に（例: 夜空を見上げる青年、アニメ調）",
                 properties: ["prompt": ["type": "string"]]),
        ToolSpec(name: "find_contact",
                 description: "Mac の連絡先から人を探して、電話番号・メール・誕生日・会社を返す。「〇〇さんの電話番号は？」「〇〇さんのメアド教えて」と聞かれたら使う。query は名前や会社名の一部",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "upcoming_birthdays",
                 description: "これから誕生日を迎える人を調べる。days は何日先まで見るか（今日だけなら 0、今週なら 7）",
                 properties: ["days": ["type": "integer", "minimum": 0, "maximum": 365]]),
        ToolSpec(name: "save_contact",
                 description: "Mac の連絡先に新しい人を登録する。名刺を読み取ったあとに使う。phone と email は複数ある場合カンマ区切り。登録前に確認が出る",
                 properties: ["family_name": ["type": "string"], "given_name": ["type": "string"],
                              "organization": ["type": "string", "optional": true],
                              "phone": ["type": "string", "optional": true], "email": ["type": "string", "optional": true],
                              "note": ["type": "string", "optional": true],
                              "job_title": ["type": "string", "optional": true]]),
        ToolSpec(name: "import_contacts",
                 description: "名刺アプリ（Eight など）から書き出した CSV を読み込んで、Mac の連絡先にまとめて登録する。file は CSV のパス。資料として登録した CSV があれば、その名前でもよい。登録前に件数を確認する",
                 properties: ["file": ["type": "string"]]),
        ToolSpec(name: "look_image", description: "ユーザーが渡した画像（ドラッグや「画像を渡す」で添付されたもの）を見る。添付があると伝えられたら、これを呼んでから答える",
                 properties: [:]),
        ToolSpec(name: "open_url", description: "Web ページ（http/https の URL）をブラウザで開く。QR コードの URL を開くときなど。開く前にユーザーに確認する",
                 properties: ["url": ["type": "string"]]),
        ToolSpec(name: "run_shortcut", description: "macOS のショートカット.app に登録されたショートカットを名前で実行する",
                 properties: ["name": ["type": "string"]]),
    ]

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// ツールを実行して (結果テキスト, エラーかどうか) を返す
    /// 呼ばれた回数（「やりました」と言いながらツールを呼んでいない答えを見つけるのに使う）
    private(set) static var callCount = 0

    static func execute(name: String, arguments: Any?) async -> (String, Bool) {
        callCount += 1
        if MCPManager.shared.handles(name) {
            return await MCPManager.shared.call(name, arguments: arguments, localAllowed: AppSettings.shared.backend == .local)
        }
        if CommandLine.arguments.contains("--llm-selftest") { print("  [tool] \(name) \(arguments ?? "")") }
        Log.write("tool call: \(name)")
        do {
            let args = try validate(name: name, arguments: arguments)
            return (try await run(name: name, args: args), false)
        } catch {
            return ("エラー: \(error.localizedDescription)", true)
        }
    }

    private static func validate(name: String, arguments: Any?) throws -> [String: Any] {
        guard let spec = builtin.first(where: { $0.name == name }) else { throw ToolError(message: "unknown tool: \(name)") }
        var raw: [String: Any] = [:]
        if let s = arguments as? String {
            if !s.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                    throw ToolError(message: "引数の JSON が不正です")
                }
                raw = obj
            }
        } else if let d = arguments as? [String: Any] {
            raw = d
        }
        var clean: [String: Any] = [:]
        for (key, prop) in spec.properties {
            guard let value = raw[key] else {
                // 省略してよい項目（"optional": true）は、無ければ空のまま進める
                if prop["optional"] as? Bool == true { continue }
                throw ToolError(message: "missing argument: \(key)")
            }
            if prop["type"] as? String == "integer" {
                // 小さいローカルモデルは "50" のように文字列で渡してくることがある
                guard let n = (value as? NSNumber)?.doubleValue ?? Double("\(value)") else {
                    throw ToolError(message: "bad type for \(key)")
                }
                clean[key] = Int(n)
            } else {
                guard let s = value as? String else { throw ToolError(message: "bad type for \(key)") }
                if let allowed = prop["enum"] as? [String], !allowed.contains(s) {
                    throw ToolError(message: "\(key) must be one of \(allowed)")
                }
                clean[key] = s
            }
        }
        return clean
    }

    private static func run(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "get_datetime":
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "yyyy年M月d日(E) H時m分"
            return f.string(from: Date())
        case "open_app":
            let app = args["name"] as! String
            try await shell("/usr/bin/open", ["-a", app])
            return "\(app) を開きました"
        case "set_volume":
            let level = max(0, min(100, args["level"] as! Int))
            try appleScript("set volume output volume \(level)")
            return "音量を \(level) にしました"
        case "get_battery":
            return try await shell("/usr/bin/pmset", ["-g", "batt"])
        case "music_control":
            let cmd = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][args["action"] as! String]!
            try appleScript("tell application \"Music\" to \(cmd)")
            return "Music: \(cmd)"
        case "search_web":
            return try await WebTools.search(query: args["query"] as! String)
        case "read_webpage":
            return try await WebTools.read(urlString: args["url"] as! String)
        case "open_web_search":
            let q = args["query"] as! String
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            NSWorkspace.shared.open(c.url!)
            return "ブラウザで「\(q)」を検索しました"
        case "get_weather":
            return try await JMAWeather.forecast(place: args["place"] as! String)
        case "open_weathernews":
            // 規約で自動取得が禁止されているため、中身は読まずにブラウザで開くだけにする
            let place = args["place"] as! String
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: "ウェザーニュース \(place) 天気"), URLQueryItem(name: "btnI", value: "1")]
            NSWorkspace.shared.open(c.url!)
            return "ブラウザでウェザーニュースの\(place)の天気を開きました"
        case "calculate":
            return try await Calculator.evaluate(args["expression"] as! String)
        case "remember":
            let text = args["text"] as! String
            let localOnly = AppSettings.shared.backend == .local && MCPManager.shared.hasLocalOnlyConnected
            return MemoryStore.shared.remember(text, localOnly: localOnly)
                ? "覚えました: \(text)" : "すでに覚えているか、内容が空です"
        case "recall":
            let hits = MemoryStore.shared.search(args["query"] as! String, localAllowed: AppSettings.shared.backend == .local)
            return hits.isEmpty ? "覚えていることの中に見つかりませんでした"
                : "覚えていること:\n" + hits.map { "・\($0.text)" }.joined(separator: "\n")
        case "forget":
            let query = args["query"] as! String
            guard await AgentController.shared.confirm("「\(query)」に当てはまる記憶を消します。よろしいですか？") else {
                return "ユーザーが取りやめました"
            }
            let removed = MemoryStore.shared.forget(matching: query)
            return removed.isEmpty ? "当てはまる記憶はありませんでした"
                : "消しました:\n" + removed.map { "・\($0.text)" }.joined(separator: "\n")
        case "look_camera":
            // AI が脈絡なくカメラを使うことがあるので、利用者の言葉に「見せている」合図があるときだけ撮る
            guard CameraAttachment.isCameraRequest(AgentController.shared.lastUserText) else {
                return "今はカメラを使う場面ではありません。カメラで見てほしいときは「これ何？」「これ読んで」などと言ってもらってください。写真は撮っていません"
            }
            let r = try await Camera.shared.look()
            var out = ["カメラで1枚撮りました（写真は画面に表示中）。"]
            out.append(r.text.isEmpty ? "写っている文字: なし" : "写っている文字:\n" + r.text.joined(separator: "\n"))
            if !r.codes.isEmpty {
                out.append("読み取ったコード:\n" + r.codes.map { "\($0.kind): \($0.value)" }.joined(separator: "\n"))
            }
            let text = out.joined(separator: "\n")
            Camera.shared.note(reading: text)
            return text
        case "search_documents":
            let query = args["query"] as! String
            let found = Library.shared.context(for: query)
            guard !found.isEmpty else {
                let count = Library.shared.sources.count
                return count == 0
                    ? "資料がまだ登録されていません。画面の本のボタンから追加できます"
                    : "登録された\(count)件の資料の中に、関係しそうな箇所は見つかりませんでした"
            }
            return "資料から見つかった箇所です。答えるときは【】の中の資料名とページを添えてください。\n\n" + found
        case "list_documents":
            let sources = Library.shared.sources
            guard !sources.isEmpty else { return "資料はまだ登録されていません" }
            return "登録されている資料 \(sources.count)件:\n" + sources.map { "・\($0.name)" }.joined(separator: "\n")
        case "add_mcp_server":
            let name = (args["name"] as! String).trimmingCharacters(in: .whitespaces)
            let url = (args["url"] as! String).trimmingCharacters(in: .whitespaces)
            let token = (args["token"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !url.isEmpty else { throw ToolError(message: "名前と URL が要ります") }
            guard await AgentController.shared.confirm("""
                外部サービス「\(name)」を登録します
                接続先: \(url)
                登録すると、このサービスの機能を私が使えるようになります。
                よろしいですか？
                """) else { return "ユーザーが取りやめました。登録していません" }
            do {
                try await MCPManager.shared.addRemoteServer(name: name, url: url, needsLogin: false,
                                                            bearerToken: token.isEmpty ? nil : token)
            } catch {
                throw ToolError(message: "登録できませんでした: \(error.localizedDescription)")
            }
            // つながるまで少し待ってから、結果を見る
            try? await Task.sleep(for: .seconds(3))
            let state = MCPManager.shared.statusText(of: name)
            return "「\(name)」を登録しました。状態: \(state)"
        case "list_mcp_servers":
            let summary = MCPManager.shared.allStatusText()
            return summary.isEmpty ? "登録されている外部サービスはありません" : summary
        case "remove_mcp_server":
            let name = (args["name"] as! String).trimmingCharacters(in: .whitespaces)
            guard await AgentController.shared.confirm("外部サービス「\(name)」の登録を外します。よろしいですか？") else {
                return "ユーザーが取りやめました。外していません"
            }
            try await MCPManager.shared.removeServer(name)
            return "「\(name)」の登録を外しました"
        case "generate_image":
            let saved = try await ImageMaker.make(prompt: args["prompt"] as! String)
            return "絵ができました（画面に出しています）。保存先: 書類 > AIエージェント > 画像 > \(saved.lastPathComponent)"
        case "find_contact":
            return try await ContactsBook.find(args["query"] as! String)
        case "upcoming_birthdays":
            return try await ContactsBook.birthdays(within: args["days"] as! Int)
        case "save_contact":
            func text(_ key: String) -> String { (args[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
            var new = ContactsBook.NewContact()
            new.familyName = text("family_name")
            new.givenName = text("given_name")
            new.organization = text("organization")
            new.jobTitle = text("job_title")
            new.phones = text("phone").split(whereSeparator: { ",、，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            new.emails = text("email").split(whereSeparator: { ",、，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            new.note = text("note")
            guard !(new.familyName + new.givenName + new.organization).isEmpty else {
                throw ToolError(message: "名前か会社名が必要です")
            }
            var summary = ["Mac の連絡先に登録します",
                           "名前: \([new.familyName, new.givenName].filter { !$0.isEmpty }.joined(separator: " "))"]
            if !new.organization.isEmpty { summary.append("会社: \(new.organization)\(new.jobTitle.isEmpty ? "" : " / \(new.jobTitle)")") }
            if !new.phones.isEmpty { summary.append("電話: \(new.phones.joined(separator: "、"))") }
            if !new.emails.isEmpty { summary.append("メール: \(new.emails.joined(separator: "、"))") }
            guard await AgentController.shared.confirm(summary.joined(separator: "\n") + "\nよろしいですか？") else {
                return "ユーザーが取りやめました。登録していません"
            }
            return try await ContactsBook.save(new)
        case "import_contacts":
            let given = (args["file"] as! String).trimmingCharacters(in: .whitespaces)
            // 資料に登録済みの CSV なら、その名前でも受け付ける
            let path = FileManager.default.fileExists(atPath: given) ? given
                : Library.shared.sources.first { $0.name.localizedCaseInsensitiveContains(given) }?.path ?? given
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError(message: "\(given) が見つかりません。CSV のパスか、資料に登録した名前を教えてください")
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .shiftJIS)) ?? ""
            let people = ContactsBook.parseCSV(text)
            guard !people.isEmpty else { throw ToolError(message: "CSV から連絡先を見つけられませんでした") }
            let names = people.prefix(3).map { [$0.familyName, $0.givenName].filter { !$0.isEmpty }.joined(separator: " ") }
            guard await AgentController.shared.confirm("Mac の連絡先に \(people.count)件を登録します\n例: \(names.joined(separator: "、"))\nよろしいですか？") else {
                return "ユーザーが取りやめました。登録していません"
            }
            return try await ContactsBook.importCSV(at: url)
        case "look_image":
            guard Camera.shared.lastPhoto != nil else { return "渡された画像がありません" }
            Camera.shared.attachmentUsed()
            var out = ["渡された画像を見ます。"]
            if let reading = Camera.shared.lastReading { out.append(reading) }
            return out.joined(separator: "\n")
        case "open_url":
            let raw = (args["url"] as! String).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ToolError(message: "http または https の URL だけ開けます")
            }
            // QR コードなど外から来た URL は、偽のサイトのこともあるので、開く前に必ず確認する
            guard await AgentController.shared.confirm("\(url.host() ?? raw) のページをブラウザで開きます。よろしいですか？\n\(raw)") else {
                return "ユーザーが開くのをやめました"
            }
            NSWorkspace.shared.open(url)
            return "ブラウザで開きました"
        case "run_shortcut":
            let n = args["name"] as! String
            let out = try await shell("/usr/bin/shortcuts", ["run", n], timeout: 60)
            return out.isEmpty ? "ショートカット「\(n)」を実行しました" : out
        default:
            throw ToolError(message: "unknown tool: \(name)")
        }
    }

    private static func appleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw ToolError(message: error[NSAppleScript.errorMessage] as? String ?? "AppleScript error") }
    }

    @discardableResult
    nonisolated private static func shell(_ path: String, _ args: [String], timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    cont.resume(throwing: ToolError(message: out.isEmpty ? "exit \(proc.terminationStatus)" : out))
                }
            }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: 動作確認用（組み込みの機能が動くかを1つずつ試す）

extension Tools {
    /// 各機能を、音量や再生状態を変えない読み取りだけの操作で1つずつ試し、結果を1行ずつ返す
    static func selfTestReport() async -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ body: () async throws -> String) async {
            do {
                let out = try await body()
                lines.append("✅ \(label): \(out.replacingOccurrences(of: "\n", with: " ").prefix(80))")
            } catch {
                lines.append("❌ \(label): \(String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(160))")
            }
        }
        lines.append("重なりを調べるカレンダー: \(AppSettings.shared.conflictCalendarList)")
        lines.append("ホーム: \(FileManager.default.homeDirectoryForCurrentUser.path)")
        await check("アプリを開く（open -a Finder）") { try await shell("/usr/bin/open", ["-a", "Finder"]) }
        await check("電池（pmset）") { try await shell("/usr/bin/pmset", ["-g", "batt"]) }
        await check("ショートカット一覧（shortcuts list）") { try await shell("/usr/bin/shortcuts", ["list"], timeout: 20) }
        await check("音量を読む（AppleScript）") {
            var error: NSDictionary?
            let r = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&error)
            if let error { throw ToolError(message: "\(error)") }
            return r?.stringValue ?? "-"
        }
        await check("ミュージックの状態（AppleScript）") {
            var error: NSDictionary?
            let r = NSAppleScript(source: "tell application \"Music\" to get player state as text")?.executeAndReturnError(&error)
            if let error { throw ToolError(message: "\(error)") }
            return r?.stringValue ?? "-"
        }
        await check("計算") { try await Calculator.evaluate("(1+2)*3") }
        await check("気象庁") { String(try await JMAWeather.forecast(place: "東京").prefix(40)) }
        await check("Web ページを読む") { String(try await WebTools.read(urlString: "https://www.jma.go.jp/").prefix(40)) }
        await check("ログの書き込み") {
            Log.write("sandbox selftest")
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AIAgent.log").path
        }
        await check("連携設定（mcp.json）") {
            let d = try Data(contentsOf: MCPManager.configURL)
            return "\(MCPManager.configURL.path) \(d.count)バイト"
        }
        await check("議事録フォルダ") {
            try FileManager.default.createDirectory(at: MeetingRecorder.folder, withIntermediateDirectories: true)
            return MeetingRecorder.folder.path
        }
        await check("キーチェーン（書いて読む）") {
            Keychain.set("ok", for: "selftest.sandbox")
            let v = Keychain.get("selftest.sandbox") ?? "読めない"
            Keychain.set("", for: "selftest.sandbox")
            return v
        }
        await check("保存済みの Tavily キー（値は出さない）") {
            guard let v = Keychain.get("tavily"), !v.isEmpty else { throw ToolError(message: "読めない") }
            return "読めた（\(v.count)文字）"
        }
        await check("uvx（Google 個人用 MCP）") { try await shell("/usr/bin/env", ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "uvx", "--version"]) }
        await check("右筆の MCP") {
            let path = "/Applications/ゆうひつ.app/Contents/MacOS/yuhitsu-mcp"
            guard FileManager.default.isExecutableFile(atPath: path) else { throw ToolError(message: "実行できない") }
            return "実行可能"
        }
        return lines
    }
}
