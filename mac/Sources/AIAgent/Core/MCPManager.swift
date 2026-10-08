import AppKit
import Foundation
import MCP
import Observation
import System

/// MCP サーバー1件分の設定。Claude Desktop などと同じ `mcpServers` 形式で書く。
///
///     { "mcpServers": {
///         "yuhitsu": { "discovery": "~/Library/Application Support/Yuhitsu/mcp.json" },
///         "files":   { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"] },
///         "remote":  { "url": "http://127.0.0.1:8080/mcp", "headers": { "Authorization": "Bearer ..." } },
///         "off":     { "command": "...", "disabled": true },
///         "private": { "command": "...", "localOnly": true } } }
///
/// `localOnly: true` のサーバーのツールは、AI がローカル（Ollama）のときだけ使える。
/// メールなど、Mac の外に出したくないデータを扱うサーバー向け（右筆は既定で true）。
struct MCPServerConfig: Codable, Equatable {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    /// 接続情報（`{"url": ..., "token": ...}`）を書き出したファイル。起動中のアプリが公開する MCP サーバー向け
    var discovery: String?
    var disabled: Bool?
    var localOnly: Bool?
    /// ログインに使う OAuth 設定の名前（mcp.json の "oauth" のキー）。Google 公式 MCP サーバーなど
    var oauth: String?
}

/// 設定ファイルの値のうち "keychain:<名前>" と書いたものは、キーチェーンから読んで使う（API キーを平文で書かないため）
enum SecretRef {
    static let prefix = "keychain:"

    static func resolve(_ value: String) -> String {
        // "keychain:名前" だけでなく、"Bearer keychain:名前" のように途中にあっても置き換える
        guard let r = value.range(of: prefix) else { return value }
        let account = String(value[r.upperBound...])
        return String(value[..<r.lowerBound]) + (Keychain.get(account) ?? "")
    }

    /// 秘密の値をキーチェーンに保存し、設定ファイルに書く参照文字列を返す。
    /// 空のときは、保存済みの値があればそれをそのまま使う（編集画面で秘密の欄を空にしておけば変更しない）
    static func store(_ value: String, account: String) -> String {
        _ = storeOrKeep(value, account: account)
        return prefix + account
    }

    static func storeOrKeep(_ value: String, account: String) -> String? {
        if !value.isEmpty {
            Keychain.set(value, for: account)
            return prefix + account
        }
        if let saved = Keychain.get(account), !saved.isEmpty { return prefix + account }
        return nil
    }

    static func has(_ account: String) -> Bool { !(Keychain.get(account) ?? "").isEmpty }
}

struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig]
    /// ブラウザでログインする MCP サーバー用の設定。複数のサーバーで1つのログインを共有できる
    var oauth: [String: OAuthConfig]?
}

enum MCPStatus: Equatable {
    case disabled, connecting, connected(tools: Int), unavailable(String)

    var label: String {
        switch self {
        case .disabled: "無効"
        case .connecting: "接続中…"
        case .connected(let n): "接続済み（ツール \(n) 個）"
        case .unavailable(let m): m
        }
    }
}

/// MCP サーバーに接続し、そのツールを AI から使えるようにする
@MainActor @Observable
final class MCPManager {
    static let shared = MCPManager()

    static let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIAgent")
        return dir.appendingPathComponent("mcp.json")
    }()

    private(set) var serverNames: [String] = []
    private(set) var status: [String: MCPStatus] = [:]
    private(set) var configError: String?

    private struct Connection {
        let client: Client
        let tools: [MCP.Tool]
        let process: Process?
    }

    private var configs: [String: MCPServerConfig] = [:]
    private(set) var oauthConfigs: [String: OAuthConfig] = [:]
    private var tokenBoxes: [String: TokenBox] = [:]
    private var connections: [String: Connection] = [:]
    /// AI に見せるツール名 → (サーバー名, 元のツール名)
    private var toolIndex: [String: (server: String, tool: String)] = [:]
    private var retryTask: Task<Void, Never>?

    private init() {}

    // MARK: 設定ファイル

    private static let defaultConfig = MCPConfigFile(mcpServers: [
        // 右筆に同梱の中継コマンド（右筆のサンドボックス内の接続情報を読み、起動中の右筆につなぐ）
        "yuhitsu": MCPServerConfig(command: "/Applications/ゆうひつ.app/Contents/MacOS/yuhitsu-mcp", localOnly: true),
    ])

    /// ローカル AI 専用のサーバーか（右筆は、設定ファイルに書かれていなくても既定でローカル専用）
    func isLocalOnly(_ server: String) -> Bool {
        configs[server]?.localOnly ?? (server == "yuhitsu")
    }

    /// ローカル専用のサーバーに接続中か
    var hasLocalOnlyConnected: Bool {
        connections.keys.contains { isLocalOnly($0) }
    }

    /// 直近の応答でローカル専用のツールを使ったか（使ったやりとりは、クラウドの AI に渡す履歴から外す）
    private var localOnlyUsed = false

    func consumeLocalOnlyUsage() -> Bool {
        defer { localOnlyUsed = false }
        return localOnlyUsed
    }

    /// 設定ファイルがなければ、右筆を登録した初期設定を作る
    func ensureConfigFile() {
        let url = Self.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(Self.defaultConfig) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// 設定を読み直し、すべてのサーバーに接続し直す
    func reload() async {
        ensureConfigFile()
        await disconnectAll()
        do {
            let data = try Data(contentsOf: Self.configURL)
            let file = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            configs = file.mcpServers
            oauthConfigs = file.oauth ?? [:]
            configError = nil
        } catch {
            configs = [:]
            oauthConfigs = [:]
            configError = "設定ファイルを読めません: \(error.localizedDescription)"
        }
        serverNames = configs.keys.sorted()
        OAuthManager.shared.refreshLoginState(Array(oauthConfigs.keys))
        for name in serverNames {
            status[name] = configs[name]?.disabled == true ? .disabled : .connecting
        }
        await withTaskGroup(of: Void.self) { group in
            for name in serverNames where configs[name]?.disabled != true {
                group.addTask { await self.connect(name) }
            }
        }
        startRetryLoop()
    }

    /// 未接続のサーバー（右筆がまだ起動していない等）に、定期的につなぎ直す
    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.refreshTokens()
                for name in self.serverNames where self.connections[name] == nil && self.configs[name]?.disabled != true {
                    await self.connect(name)
                }
            }
        }
    }

    /// ログイン済みのトークンを、期限が切れる前に更新して接続中のサーバーに渡す
    private func refreshTokens() async {
        for (name, box) in tokenBoxes {
            guard let oc = oauthConfigs[name] else { continue }
            if let t = try? await OAuthManager.shared.accessToken(name, config: oc) { box.token = t }
        }
    }

    /// 設定画面の「ログイン」。成功したら、そのログインを使うサーバーにつなぎ直す
    func login(_ oauthName: String) async throws {
        guard let oc = oauthConfigs[oauthName] else { return }
        try await OAuthManager.shared.login(oauthName, config: oc)
        for name in serverNames where configs[name]?.oauth == oauthName && configs[name]?.disabled != true {
            status[name] = .connecting
            await connect(name)
        }
    }

    func logout(_ oauthName: String) async {
        OAuthManager.shared.logout(oauthName)
        for name in serverNames where configs[name]?.oauth == oauthName {
            if let c = connections[name] { await c.client.disconnect() }
            connections[name] = nil
            status[name] = .unavailable(OAuthError.needsLogin.message)
        }
        rebuildToolIndex()
    }

    /// 「内容を Mac の外に出さない」の切り替え
    func setLocalOnly(_ names: [String], _ on: Bool) async throws {
        try await updateConfigFile { file in
            for n in names where file.mcpServers[n] != nil { file.mcpServers[n]?.localOnly = on ? true : nil }
        }
    }

    /// AI への指示に書く「今つながっているサービス」の説明
    /// 1つのサーバーの状態を、人に読める言葉で返す
    func statusText(of name: String) -> String {
        switch status[name] {
        case .connected: "つながりました（ツール \(toolNames(of: name).count) 個）"
        case .connecting: "接続中"
        case .disabled: "無効"
        case .unavailable(let message): "つながりません（\(message)）"
        case .none: "登録されていません"
        }
    }

    /// すべてのサーバーの状態（会話で聞かれたときに使う）
    func allStatusText() -> String {
        serverNames.map { "・\($0): \(statusText(of: $0))" }.joined(separator: "\n")
    }

    func connectedSummary(includeLocalOnly: Bool) -> String {
        var names: [String] = []
        for n in serverNames {
            guard case .connected = status[n], includeLocalOnly || !isLocalOnly(n) else { continue }
            let label: String
            switch n {
            case "google-personal": label = "Google（カレンダー・Gmail・Drive・ドキュメント・スプレッドシート・スライド）。ツール名は google-personal__ で始まる"
            case "yuhitsu": label = "右筆（メール）。ツール名は yuhitsu__ で始まる"
            default: label = "\(n)。ツール名は \(n)__ で始まる"
            }
            if !names.contains(label) { names.append(label) }
        }
        return names.map { "  - " + $0 }.joined(separator: "\n")
    }

    /// アプリが自動で入れる引数（個人の Google のツールは、登録した Gmail アドレス。予定の取得は件数を多めに）
    private func autoArgs(for server: String, tool: String) -> [String: Value] {
        guard server == "google-personal" else { return [:] }
        var out: [String: Value] = [:]
        if let email = configs[server]?.env?["USER_GOOGLE_EMAIL"], !email.isEmpty { out["user_google_email"] = .string(email) }
        if tool == "get_events" { out["max_results"] = .int(50) }
        return out
    }

    // MARK: 設定画面の表示用

    func config(_ name: String) -> MCPServerConfig? { configs[name] }

    /// 個人の Google（workspace-mcp）にログイン済みか（ログインすると認証情報のファイルができる）
    var isGooglePersonalLoggedIn: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".google_workspace_mcp/credentials")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasSuffix(".json") && $0 != "oauth_states.json" }
    }

    /// 連携を外す。設定ファイルから消し、その連携用に保存したキーやログイン情報も消す
    func removeServer(_ name: String) async throws {
        let oauthName = configs[name]?.oauth
        try await updateConfigFile { file in
            file.mcpServers[name] = nil
            if let oauthName, !file.mcpServers.values.contains(where: { $0.oauth == oauthName }) {
                file.oauth?[oauthName] = nil
            }
        }
        if let oauthName, !configs.values.contains(where: { $0.oauth == oauthName }) { OAuthManager.shared.logout(oauthName) }
        let base = name.hasPrefix("google-work-") ? "google-work" : name
        for suffix in ["secret", "token", "apikey", "password"] where SecretRef.has("mcp.\(base).\(suffix)") {
            if base == "google-work", configs.keys.contains(where: { $0.hasPrefix("google-work-") }) { continue }
            Keychain.set("", for: "mcp.\(base).\(suffix)")
        }
        status[name] = nil
    }

    // MARK: Google の追加（設定画面から）

    struct GoogleService: Identifiable, Hashable {
        let id: String
        let label: String
        let url: String
        let scopes: [String]
    }

    /// Google 公式の Workspace MCP サーバー（開発者プレビュー。Google Workspace アカウントが必要）
    static let googleServices: [GoogleService] = [
        .init(id: "gmail", label: "Gmail", url: "https://gmailmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"]),
        .init(id: "calendar", label: "カレンダー", url: "https://calendarmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                       "https://www.googleapis.com/auth/calendar.events.freebusy",
                       "https://www.googleapis.com/auth/calendar.events.readonly"]),
        .init(id: "drive", label: "Drive", url: "https://drivemcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/drive.file"]),
        .init(id: "docs", label: "ドキュメント", url: "https://docsmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/documents.readonly"]),
        .init(id: "sheets", label: "スプレッドシート", url: "https://sheetsmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/spreadsheets.readonly"]),
        .init(id: "slides", label: "スライド", url: "https://slidesmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/presentations.readonly"]),
    ]

    private func updateConfigFile(_ change: (inout MCPConfigFile) -> Void) async throws {
        ensureConfigFile()
        let data = try Data(contentsOf: Self.configURL)
        var file = try JSONDecoder().decode(MCPConfigFile.self, from: data)
        change(&file)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(file).write(to: Self.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
        await reload()
    }

    /// 会社の Google Workspace（公式 MCP サーバー）を追加する。ログインは設定画面の「ログイン」から
    func addGoogleWorkspace(clientId: String, clientSecret: String, services: Set<String>, localOnly: Bool) async throws {
        let chosen = Self.googleServices.filter { services.contains($0.id) }
        guard !chosen.isEmpty else { return }
        try await updateConfigFile { file in
            for svc in Self.googleServices { file.mcpServers["google-work-\(svc.id)"] = nil }
            for svc in chosen {
                file.mcpServers["google-work-\(svc.id)"] = MCPServerConfig(url: svc.url, localOnly: localOnly ? true : nil, oauth: "google-work")
            }
            var oauth = file.oauth ?? [:]
            var scopes: [String] = []
            for sc in chosen.flatMap(\.scopes) where !scopes.contains(sc) { scopes.append(sc) }
            oauth["google-work"] = OAuthConfig(clientId: clientId,
                                               clientSecret: SecretRef.storeOrKeep(clientSecret, account: "mcp.google-work.secret"),
                                               scopes: scopes)
            file.oauth = oauth
        }
    }

    /// 個人の Gmail など（有志の workspace-mcp を Mac の中で動かす）を追加する。ログインは初めて使うときにブラウザで
    func addGooglePersonal(clientId: String, clientSecret: String, email: String, localOnly: Bool) async throws {
        try await updateConfigFile { file in
            file.mcpServers["google-personal"] = MCPServerConfig(
                command: "uvx",
                args: ["workspace-mcp", "--single-user", "--tool-tier", "core", "--permissions",
                       "gmail:drafts", "calendar:full", "drive:readonly", "docs:readonly", "sheets:readonly", "slides:readonly"],
                env: ["GOOGLE_OAUTH_CLIENT_ID": clientId,
                      "GOOGLE_OAUTH_CLIENT_SECRET": SecretRef.store(clientSecret, account: "mcp.google-personal.secret"),
                      "USER_GOOGLE_EMAIL": email, "OAUTHLIB_INSECURE_TRANSPORT": "1"],
                localOnly: localOnly ? true : nil)
        }
    }

    // MARK: 業務サービスの追加（設定画面から）

    /// Backlog（ヌーラボ公式の MCP サーバー）
    func addBacklog(domain: String, apiKey: String) async throws {
        let host = domain.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await updateConfigFile { file in
            file.mcpServers["backlog"] = MCPServerConfig(
                command: "npx", args: ["-y", "backlog-mcp-server"],
                env: ["BACKLOG_DOMAIN": host,
                      "BACKLOG_API_KEY": SecretRef.store(apiKey, account: "mcp.backlog.apikey"),
                      "ENABLE_TOOLSETS": "space,project,issue,wiki,notifications,document"])
        }
    }

    /// kintone（サイボウズ公式の MCP サーバー）。API トークンか、ログイン名とパスワードのどちらか
    func addKintone(baseURL: String, apiToken: String, username: String, password: String) async throws {
        var env = ["KINTONE_BASE_URL": baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        if let ref = SecretRef.storeOrKeep(apiToken, account: "mcp.kintone.token") { env["KINTONE_API_TOKEN"] = ref }
        if !username.isEmpty {
            env["KINTONE_USERNAME"] = username
            env["KINTONE_PASSWORD"] = SecretRef.store(password, account: "mcp.kintone.password")
        }
        try await updateConfigFile { file in
            file.mcpServers["kintone"] = MCPServerConfig(command: "npx", args: ["-y", "@kintone/mcp-server"], env: env)
        }
    }

    /// Salesforce（Salesforce が提供する Hosted MCP サーバー）。ログインはブラウザで
    func addSalesforce(serverURL: String, myDomain: String, clientId: String, clientSecret: String) async throws {
        let base = "https://" + myDomain.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await updateConfigFile { file in
            file.mcpServers["salesforce"] = MCPServerConfig(url: serverURL, oauth: "salesforce")
            var oauth = file.oauth ?? [:]
            oauth["salesforce"] = OAuthConfig(
                clientId: clientId,
                clientSecret: SecretRef.storeOrKeep(clientSecret, account: "mcp.salesforce.secret"),
                scopes: ["mcp_api", "refresh_token"],
                authorizeUrl: base + "/services/oauth2/authorize",
                tokenUrl: base + "/services/oauth2/token")
            file.oauth = oauth
        }
    }

    /// URL だけで MCP サーバーを追加する。ログインが必要なら、標準の自動検出と自動登録を試す
    func addRemoteServer(name: String, url: String, needsLogin: Bool, clientId: String? = nil, clientSecret: String? = nil,
                         bearerToken: String? = nil, localOnly: Bool = false) async throws {
        guard let u = URL(string: url), u.scheme == "https" || u.host == "127.0.0.1" || u.host == "localhost" else {
            throw OAuthError(message: "https の URL を入れてください")
        }
        var oauthConfig: OAuthConfig?
        if needsLogin {
            var oc = try await OAuthDiscovery.discover(serverURL: u, redirectURI: OAuthConfig(clientId: "", scopes: []).redirectURI,
                                                       clientId: clientId, clientSecret: clientSecret)
            if let secret = oc.clientSecret { oc.clientSecret = SecretRef.store(secret, account: "mcp.\(name).secret") }
            oauthConfig = oc
        }
        try await updateConfigFile { file in
            var headers: [String: String]?
            if let bearerToken, let ref = SecretRef.storeOrKeep(bearerToken, account: "mcp.\(name).token") {
                headers = ["Authorization": "Bearer " + ref]
            }
            file.mcpServers[name] = MCPServerConfig(url: url, headers: headers, localOnly: localOnly ? true : nil,
                                                    oauth: oauthConfig == nil ? nil : name)
            if let oauthConfig {
                var oauth = file.oauth ?? [:]
                oauth[name] = oauthConfig
                file.oauth = oauth
            }
        }
    }

    // MARK: 書き込み前の確認

    /// 書き込み系のツールか（読むだけと明示されていれば不要。削除などの破壊的な操作や、名前が書き込みを表すものは確認する）
    private func needsConfirmation(_ tool: MCP.Tool) -> Bool {
        if tool.annotations.readOnlyHint == true { return false }
        if tool.annotations.destructiveHint == true { return true }
        let n = tool.name.lowercased()
        let verbs = ["add", "create", "update", "delete", "remove", "post", "send", "deploy", "move", "edit", "write",
                     "insert", "upload", "comment", "close", "merge", "manage", "modify", "set_", "set-", "put", "patch", "draft"]
        return verbs.contains { n.contains($0) }
    }

    /// サービスの呼び名（設定ファイル上の名前は、人には分かりにくい）
    private static let serviceLabels: [String: String] = [
        "yuhitsu": "右筆（メール）", "google-personal": "Google", "notion": "Notion", "slack": "Slack",
        "github": "GitHub", "freee": "freee", "hubspot": "HubSpot", "salesforce": "Salesforce",
        "backlog": "Backlog", "kintone": "kintone", "zapier": "Zapier", "figma": "Figma",
    ]

    /// よくある操作を、日本語の言い方にする
    private static func actionPhrase(server: String, tool: String, args: [String: Value]) -> String? {
        func text(_ key: String) -> String? {
            if case .string(let v)? = args[key], !v.isEmpty { return v }
            return nil
        }
        let action = text("action")?.lowercased() ?? ""
        switch tool {
        case "manage_event":
            switch action {
            case "delete": return "Google カレンダーの予定を削除します"
            case "update": return "Google カレンダーの予定を変更します"
            case "create": return "Google カレンダーに予定を追加します"
            default: return "Google カレンダーの予定を操作します"
            }
        default: break
        }
        let t = tool.lowercased()
        if t.contains("draft") { return "メールの下書きを作ります" }
        if t.contains("send") || t.contains("post") { return "メッセージを送ります" }
        if t.contains("delete") || t.contains("remove") || t.contains("trash") { return "削除します" }
        if t.contains("create") || t.contains("add") || t.contains("insert") { return "新しく作ります" }
        if t.contains("update") || t.contains("edit") || t.contains("modify") || t.contains("patch") { return "内容を変更します" }
        return nil
    }

    /// 日時をそのまま読ませると分かりにくいので、「9月23日(水) 13時30分」の形にする
    private static func friendlyTime(_ value: String) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoNoSec = ISO8601DateFormatter()
        isoNoSec.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: value) ?? isoNoSec.date(from: value) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        // ちょうどの時刻は「13時」、それ以外は「13時30分」と読みやすくする
        f.dateFormat = Calendar.current.component(.minute, from: date) == 0 ? "M月d日(E) H時" : "M月d日(E) H時m分"
        return f.string(from: date)
    }

    /// 予定を入れる・動かすとき、その時間帯にすでに入っている予定を調べる（終日の予定は数えない）
    private func overlappingEvents(server: String, tool: String, args: [String: Value]) async -> [String] {
        guard server == "google-personal", tool == "manage_event",
              case .string(let action)? = args["action"], ["create", "update"].contains(action.lowercased()),
              case .string(let start)? = args["start_time"], case .string(let end)? = args["end_time"],
              let c = connections[server] else { return [] }
        // 仕事用など、主カレンダー以外にも予定があるので、設定で選んだカレンダーを順に調べる
        var found: [String] = []
        for calendar in AppSettings.shared.conflictCalendarList.prefix(6) {
            var query: [String: Value] = ["time_min": .string(start), "time_max": .string(end),
                                          "max_results": .int(20), "calendar_id": .string(calendar)]
            for (k, v) in autoArgs(for: server, tool: "get_events") where query[k] == nil { query[k] = v }
            do {
                let result = try await withTimeout(seconds: 15) {
                    try await c.client.callTool(name: "get_events", arguments: query)
                }
                let text = Self.simplifyEvents(result.content.map(Self.render).joined(separator: "\n"))
                found += text.components(separatedBy: .newlines)
                    .filter { $0.contains("〜") && !$0.contains("終日") }
                    // 確認では ID を読ませない
                    .map { $0.replacingOccurrences(of: #"\s*\[ID: [^\]]+\]"#, with: "", options: .regularExpression) }
            } catch {
                Log.write("overlap check failed (\(calendar)): \(error.localizedDescription)")
            }
        }
        // 同じ予定が複数のカレンダーに入っていることがあるので、重複は除く
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// 確認のために読み上げる説明。何がどう変わるのかが分かる言い方にする
    private func describe(server: String, tool: MCP.Tool, args: [String: Value], conflicts: [String] = []) -> String {
        let label = Self.serviceLabels[server] ?? server
        let phrase = Self.actionPhrase(server: server, tool: tool.name, args: args)
            ?? "\(label)で「\(tool.annotations.title ?? tool.title ?? tool.name)」を実行します"
        var lines: [String] = [phrase.hasPrefix("Google") || phrase.hasPrefix(label) ? phrase : "\(label)で\(phrase)"]

        func string(_ key: String) -> String? {
            if case .string(let v)? = args[key], !v.isEmpty { return v }
            return nil
        }
        // 件名や本文など、内容が分かるもの
        let titleKeys = ["summary", "title", "subject", "name", "query", "content", "body", "description", "text", "message"]
        if let title = titleKeys.compactMap(string).first {
            lines.append("内容: \(title.prefix(80))")
        }
        // 日時
        if let start = string("start_time") {
            let from = Self.friendlyTime(start) ?? start
            if let end = string("end_time"), let to = Self.friendlyTime(end) {
                // 同じ日なら、終わりの時刻だけを出す（9月23日(水) 13時30分 〜 16時35分）
                let sameDay = to.prefix(while: { $0 != ")" }) == from.prefix(while: { $0 != ")" })
                let endText = sameDay
                    ? (to.split(separator: ")").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? to)
                    : to
                lines.append("日時: \(from) 〜 \(endText)")
            } else {
                lines.append("日時: \(from)")
            }
        }
        if let to = string("to") { lines.append("宛先: \(to)") }
        if let place = string("location") { lines.append("場所: \(place)") }
        if !conflicts.isEmpty {
            lines.append("この時間には、すでに次の予定が入っています:")
            lines += conflicts.prefix(4).map { "・\($0)" }
            if conflicts.count > 4 { lines.append("・ほか\(conflicts.count - 4)件") }
            return lines.joined(separator: "\n") + "\n重なりますが、よろしいですか？"
        }
        return lines.joined(separator: "\n") + "\nよろしいですか？"
    }

    // MARK: 接続

    private func connect(_ name: String) async {
        guard let config = configs[name] else { return }
        do {
            let client = Client(name: "AIエージェント", version: "0.1.0")
            var process: Process?
            let transport: any Transport
            if let command = config.command {
                let (p, t) = try launchStdio(command: command, args: config.args ?? [], env: config.env ?? [:])
                process = p
                transport = t
            } else {
                let (url, headers) = try resolveHTTP(config)
                // ログインが必要なサーバーは、リクエストのたびに最新のアクセストークンを付ける
                var box: TokenBox?
                if let oauthName = config.oauth {
                    guard let oc = oauthConfigs[oauthName] else { throw MCPSetupError("OAuth 設定「\(oauthName)」が mcp.json にありません") }
                    let b = tokenBoxes[oauthName] ?? TokenBox()
                    tokenBoxes[oauthName] = b
                    b.token = try await OAuthManager.shared.accessToken(oauthName, config: oc)
                    box = b
                }
                transport = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
                    var r = request
                    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                    if let box { r.setValue("Bearer \(box.token)", forHTTPHeaderField: "Authorization") }
                    return r
                })
            }
            _ = try await withTimeout(seconds: 20) { try await client.connect(transport: transport) }
            var tools: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let page = try await client.listTools(cursor: cursor)
                tools += page.tools
                cursor = page.nextCursor
            } while cursor != nil
            connections[name] = Connection(client: client, tools: tools, process: process)
            status[name] = .connected(tools: tools.count)
            Log.write("MCP connected: \(name) (\(tools.count) tools)")
        } catch {
            connections[name] = nil
            status[name] = .unavailable(Self.describe(error, name: name, config: config))
        }
        rebuildToolIndex()
    }

    /// アプリ終了時に、stdio で起動した MCP サーバーのプロセスを確実に止める
    func terminateProcesses() {
        for (_, c) in connections { c.process?.terminate() }
    }

    private func disconnectAll() async {
        for (_, c) in connections {
            await c.client.disconnect()
            c.process?.terminate()
        }
        connections.removeAll()
        rebuildToolIndex()
    }

    private func resolveHTTP(_ config: MCPServerConfig) throws -> (URL, [String: String]) {
        if let discovery = config.discovery {
            let path = (discovery as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path) else {
                throw MCPSetupError("起動していないか、連携が OFF です")
            }
            struct Discovery: Decodable { let url: String; let token: String? }
            let d = try JSONDecoder().decode(Discovery.self, from: data)
            guard let url = URL(string: d.url) else { throw MCPSetupError("接続情報の URL が不正です") }
            var headers = (config.headers ?? [:]).mapValues(SecretRef.resolve)
            if let token = d.token { headers["Authorization"] = "Bearer \(token)" }
            return (url, headers)
        }
        guard let s = config.url, let url = URL(string: s) else {
            throw MCPSetupError("command か url を指定してください")
        }
        return (url, (config.headers ?? [:]).mapValues(SecretRef.resolve))
    }

    /// コマンドを起動し、標準入出力で MCP を話す
    private func launchStdio(command: String, args: [String], env: [String: String]) throws -> (Process, StdioTransport) {
        // 絶対パスのコマンドが無ければ、起動を試さずに「未インストール」とする（1分ごとの再接続で無駄に起動しないように）
        let path = (command as NSString).expandingTildeInPath
        if path.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: path) {
            throw MCPSetupError("インストールされていません")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [path] + args.map { ($0 as NSString).expandingTildeInPath }
        // GUI アプリは PATH が最小限なので、Homebrew などの場所を足す
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        env.forEach { environment[$0] = SecretRef.resolve($1) }
        p.environment = environment
        let toServer = Pipe(), fromServer = Pipe()
        p.standardInput = toServer
        p.standardOutput = fromServer
        p.standardError = FileHandle.nullDevice
        try p.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor)
        )
        return (p, transport)
    }

    private static func describe(_ error: Error, name: String, config: MCPServerConfig) -> String {
        if let e = error as? MCPSetupError { return e.message }
        if let e = error as? OAuthError { return e.message }
        if error is TimeoutError { return "応答がありません（タイムアウト）" }
        if error.localizedDescription.localizedCaseInsensitiveContains("connection closed") {
            return "接続を閉じられました（相手のアプリが起動していないか、連携が OFF の可能性があります）"
        }
        return "接続できません: \(error.localizedDescription)"
    }

    // MARK: ツール

    private func rebuildToolIndex() {
        toolIndex.removeAll()
        for name in serverNames {
            guard let c = connections[name] else { continue }
            for t in c.tools {
                toolIndex[Self.exposedName(server: name, tool: t.name)] = (name, t.name)
            }
        }
    }

    /// AI 各社の制限（英数字・_・- のみ、64文字まで）に合わせたツール名
    private static func exposedName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let cleaned = String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return String(cleaned.prefix(64))
    }

    /// 話題ごとの言葉と、それに当たるツール名・サーバー名の手がかり。
    /// ローカル AI は道具が多すぎると使わなくなるので、質問に関係するものだけを渡すのに使う
    private static let topics: [(words: [String], hints: [String])] = [
        (["予定", "スケジュール", "カレンダー", "会議", "ミーティング", "打ち合わせ", "アポ", "空いて", "空き"], ["calendar", "event", "freebusy"]),
        (["メール", "受信", "返信", "下書き", "gmail", "差出人", "未読"], ["gmail", "mail", "message", "draft", "yuhitsu"]),
        (["ドライブ", "drive", "ファイル", "資料", "ドキュメント", "スプレッドシート", "シート", "スライド", "プレゼン", "表"], ["drive", "doc", "sheet", "presentation", "slide", "file"]),
        (["notion", "ノーション", "ページ", "議事録", "データベース"], ["notion"]),
        (["slack", "スラック", "チャンネル"], ["slack"]),
        (["github", "ギットハブ", "issue", "イシュー", "プルリク", "リポジトリ", "pr"], ["github"]),
        (["backlog", "バックログ", "課題", "チケット"], ["backlog"]),
        (["kintone", "キントーン", "レコード"], ["kintone"]),
        (["freee", "フリー", "請求", "会計", "経費", "入金", "仕訳", "給与"], ["freee"]),
        (["商談", "取引", "顧客", "コンタクト", "リード", "hubspot", "ハブスポット", "salesforce", "セールスフォース"], ["hubspot", "salesforce"]),
        (["zapier", "ザピアー"], ["zapier"]),
        (["figma", "フィグマ", "デザイン", "フレーム"], ["figma"]),
    ]

    /// AI に渡すツール定義（組み込みツールと同じ形式）。クラウドの AI にはローカル専用のサーバーのツールを見せない。
    /// query を渡すと、その話題に関係するツールだけに絞る（ローカル AI 向け）
    /// よく使うツールは、日本語の説明と、必要な引数だけに絞ったものを渡す
    /// （サーバーの説明は英語で、引数が30個以上あることもあり、小さいモデルが使いこなせない）
    private static let toolOverrides: [String: (description: String, keep: [String])] = [
        "google-personal/manage_event": (
            "Google カレンダーの予定を作る・変える・消す。action は create / update / delete。予定を入れると頼まれたら必ずこれを呼ぶ。start_time と end_time は 2026-09-23T18:00:00+09:00 の形式。終了時刻が分からなければ開始の1時間後にする",
            ["action", "summary", "start_time", "end_time", "event_id", "description", "location", "attendees", "calendar_id"]),
        "google-personal/create_drive_folder": (
            "Google ドライブにフォルダを作る。folder_name はフォルダ名。parent_folder_id は親フォルダの ID（ドライブの URL の /folders/ のあとの文字列）。親を指定しないとマイドライブの直下に作る",
            ["folder_name", "parent_folder_id"]),
        "google-personal/search_drive_files": (
            "Google ドライブのファイルやフォルダを探す。query は Drive の検索式。例: 親フォルダの中のフォルダ一覧は \"'親フォルダのID' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false\"、名前で探すときは \"name contains '勤務表'\"",
            ["query", "page_size"]),
        "google-personal/read_sheet_values": (
            "Google スプレッドシートの中身を読む。spreadsheet_id はシートの URL の /d/ のあとの文字列。range_name は「シート1!A:B」のような範囲",
            ["spreadsheet_id", "range_name"]),
        "google-personal/get_events": (
            "Google カレンダーの予定を読む。time_min と time_max は 2026-09-23T00:00:00+09:00 の形式",
            ["time_min", "time_max", "calendar_id", "query"]),
    ]

    func toolSpecs(includeLocalOnly: Bool, query: String? = nil) -> [ToolSpec] {
        var hints: [String]?
        if let query {
            let q = query.lowercased()
            hints = Self.topics.filter { $0.words.contains(where: q.contains) }.flatMap(\.hints)
            // サーバー名がそのまま出てきたら、そのサーバーのツールを全部
            hints! += serverNames.filter { q.contains($0.lowercased()) }
            // 話題の表に載っていないサーバー（あとから登録したもの）は、いつでも候補に入れる。
            // 入れないと、せっかく登録しても使われない
            hints! += serverNames.filter { name in
                !Self.topics.flatMap(\.hints).contains { name.lowercased().contains($0) }
            }
        }
        return serverNames.flatMap { name -> [ToolSpec] in
            guard let c = connections[name], includeLocalOnly || !isLocalOnly(name) else { return [] }
            let tools = c.tools.filter { t in
                guard let hints else { return true }
                let key = (name + " " + t.name).lowercased()
                return hints.contains { key.contains($0) }
            }
            return tools.map { t in
                var schema = Self.toAny(t.inputSchema) as? [String: Any] ?? [:]
                schema.removeValue(forKey: "$schema")
                // アプリが自動で入れる引数は、AI には見せない（AI が別の値を入れて失敗したり、件数を絞りすぎたりするのを防ぐ）
                let hidden = Set(autoArgs(for: name, tool: t.name).keys)
                if !hidden.isEmpty {
                    var props = schema["properties"] as? [String: Any] ?? [:]
                    hidden.forEach { props.removeValue(forKey: $0) }
                    schema["properties"] = props
                    if let req = schema["required"] as? [String] { schema["required"] = req.filter { !hidden.contains($0) } }
                }
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                var desc = "[\(name)] " + (t.description ?? t.title ?? t.name)
                if let override = Self.toolOverrides["\(name)/\(t.name)"] {
                    desc = "[\(name)] " + override.description
                    var props = schema["properties"] as? [String: Any] ?? [:]
                    props = props.filter { override.keep.contains($0.key) }
                    schema["properties"] = props
                    if let req = schema["required"] as? [String] { schema["required"] = req.filter { props[$0] != nil } }
                }
                return ToolSpec(name: Self.exposedName(server: name, tool: t.name), description: desc, schema: schema)
            }
        }
    }

    /// Google のカレンダー一覧（設定画面で、重なりを調べる対象を選ぶのに使う）
    func googleCalendars() async -> [(id: String, name: String)] {
        guard let c = connections["google-personal"] else { return [] }
        var args: [String: Value] = [:]
        for (k, v) in autoArgs(for: "google-personal", tool: "list_calendars") { args[k] = v }
        guard let result = try? await withTimeout(seconds: 20, { try await c.client.callTool(name: "list_calendars", arguments: args) }) else { return [] }
        let text = result.content.map(Self.render).joined(separator: "\n")
        guard let re = try? NSRegularExpression(pattern: #"- "(.*?)" \(ID: (\S+?)\)"#) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 1)))
        }
    }

    func handles(_ toolName: String) -> Bool { toolIndex[toolName] != nil }

    /// サーバーごとのツール名一覧（設定画面の表示用）
    func toolNames(of server: String) -> [String] {
        connections[server]?.tools.map(\.name) ?? []
    }

    /// MCP ツールを呼び出し、テキストにして返す
    func call(_ toolName: String, arguments: Any?, localAllowed: Bool) async -> (String, Bool) {
        guard let (server, tool) = toolIndex[toolName], let c = connections[server] else {
            return ("エラー: ツール \(toolName) は現在使えません", true)
        }
        if isLocalOnly(server) {
            // 念のため実行時にも確認する（ツール一覧から外していても、呼ばれたら拒否する）
            guard localAllowed else {
                return ("エラー: このツールはデータを Mac の外に出さないため、AI がローカルのときだけ使えます。AI をローカルに切り替えるよう伝えてください", true)
            }
            localOnlyUsed = true
        }
        var args: [String: Value] = [:]
        if let s = arguments as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            args = obj.mapValues(Self.toValue)
        } else if let d = arguments as? [String: Any] {
            args = d.mapValues(Self.toValue)
        }
        for (k, v) in autoArgs(for: server, tool: tool) { args[k] = v }
        if server == "google-personal", tool == "get_events" { Self.localizeDayRange(&args) }
        if let spec = c.tools.first(where: { $0.name == tool }), needsConfirmation(spec) {
            // 予定を入れる前に、同じ時間帯に何か入っていないか調べて、確認のときに伝える
            let conflicts = await overlappingEvents(server: server, tool: tool, args: args)
            let ok = await AgentController.shared.confirm(describe(server: server, tool: spec, args: args, conflicts: conflicts))
            if !ok {
                return ("ユーザーが実行を取りやめました。実行していないことを伝えてください", true)
            }
        }
        let finalArgs = args
        Log.write("MCP call: \(server) / \(tool)")
        if CommandLine.arguments.contains("--llm-selftest") { print("  [MCP] \(server) / \(tool) \(args)") }  // 引数や結果（メール本文など）は記録しない
        do {
            let result = try await withTimeout(seconds: 60) { try await c.client.callTool(name: tool, arguments: finalArgs) }
            var text = result.content.map(Self.render).joined(separator: "\n")
            if tool == "get_events" { text = Self.simplifyEvents(text) }
            return (text.isEmpty ? "（結果なし）" : String(text.prefix(20000)), result.isError ?? false)
        } catch {
            // 接続が切れていたら、次回以降のためにつなぎ直しておく
            connections[server] = nil
            status[server] = .unavailable("接続が切れました")
            rebuildToolIndex()
            Task { await connect(server) }
            return ("エラー: \(error.localizedDescription)", true)
        }
    }

    /// 「2026-09-24」のような日付だけの指定は世界標準時の0時（日本の9時）として扱われ、朝の予定が漏れる。
    /// 日本時間のその日の0時〜翌日0時に直す
    static func localizeDayRange(_ args: inout [String: Value]) {
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        // 日付だけ、または「0時ちょうど」（Z や時差なし）の指定は、その日の区切りを意味しているとみなす
        func day(_ key: String) -> Date? {
            guard case .string(let v) = args[key], v.count >= 10 else { return nil }
            let rest = v.dropFirst(10)
            guard rest.isEmpty || ["T00:00:00Z", "T00:00:00", "T00:00:00.000Z", "T00:00Z", "T00:00"].contains(String(rest)) else { return nil }
            return dateOnly.date(from: String(v.prefix(10)))
        }
        if let start = day("time_min") {
            args["time_min"] = .string(iso.string(from: start))
            if args["time_max"] == nil, let next = Calendar.current.date(byAdding: .day, value: 1, to: start) {
                args["time_max"] = .string(iso.string(from: next))
            }
        }
        if case .string(let v) = args["time_max"], v.count == 10, let end = day("time_max"),
           let next = Calendar.current.date(byAdding: .day, value: 1, to: end) {
            args["time_max"] = .string(iso.string(from: next))  // 日付だけの「〜24日まで」は24日の終わりまで
        } else if let end = day("time_max") {
            args["time_max"] = .string(iso.string(from: end))  // 「25日0時まで」は日本時間の25日0時まで
        }
    }

    /// カレンダーの結果（ID・リンク・英語の曜日などを含む長い形式）を、読み上げやすい短い日本語にする
    static func simplifyEvents(_ text: String) -> String {
        // 予定を消したり直したりするには ID が要るので、短くしても ID は残す
        guard let re = try? NSRegularExpression(pattern: #"- "(.*?)" \(Starts: (\S+) .*?Ends: (\S+)"#),
              let idRe = try? NSRegularExpression(pattern: #"ID: (\S+)"#) else { return text }
        let day = DateFormatter()
        day.locale = Locale(identifier: "ja_JP")
        day.dateFormat = "M月d日(E)"
        let hm = DateFormatter()
        hm.dateFormat = "H:mm"
        let iso = ISO8601DateFormatter()
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: line, range: whole) else { continue }
            let title = ns.substring(with: m.range(at: 1))
            let start = ns.substring(with: m.range(at: 2))
            let end = ns.substring(with: m.range(at: 3))
            var id = ""
            if let idMatch = idRe.firstMatch(in: line, range: whole) {
                id = " [ID: \(ns.substring(with: idMatch.range(at: 1)))]"
            }
            if let s = iso.date(from: start) {
                let e = iso.date(from: end)
                lines.append("\(day.string(from: s)) \(hm.string(from: s))〜\(e.map { hm.string(from: $0) } ?? "") \(title)\(id)")
            } else if let d = dateOnly.date(from: start) {
                lines.append("\(day.string(from: d)) 終日 \(title)\(id)")
            }
        }
        guard !lines.isEmpty else { return text }
        return "予定は\(lines.count)件（時刻順）。ID は予定を消す・直すときだけ使い、読み上げには出さない:\n" + lines.joined(separator: "\n")
    }

    private static func render(_ content: MCP.Tool.Content) -> String {
        switch content {
        case .text(let text, _, _): return text
        case .image(_, let mimeType, _, _): return "（画像: \(mimeType)）"
        case .resourceLink(let uri, let name, _, _, _, _): return "（リンク: \(name) \(uri)）"
        default: return "（テキスト以外の結果）"
        }
    }

    // MARK: Value ⇄ JSON

    static func toAny(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d.base64EncodedString()
        case .array(let a): return a.map(toAny)
        case .object(let o): return o.mapValues(toAny)
        }
    }

    static func toValue(_ any: Any) -> Value {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(toValue))
        case let o as [String: Any]: return .object(o.mapValues(toValue))
        default: return .null
        }
    }
}

struct MCPSetupError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
