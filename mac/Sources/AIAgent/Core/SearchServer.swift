import Foundation

/// 自分の Mac で動かす Web 検索（RustXNG）。API キーも回数の上限もなく、
/// 上位のページの本文までまとめて返すので、小さいモデルでも出典を読んで答えられる。
/// 入っていなければ、今までどおり Tavily で検索する
@MainActor
@Observable
final class SearchServer {
    static let shared = SearchServer()

    private(set) var running = false
    private(set) var starting = false

    /// この Mac の中だけで待ち受ける（ほかの機器からは使えない）
    private let host = "http://127.0.0.1:8888"

    @discardableResult
    func check() async -> Bool {
        var request = URLRequest(url: URL(string: "\(host)/healthz")!)
        request.timeoutInterval = 2
        let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
        running = ok
        return ok
    }

    /// 起動して、使えるようになるまで待つ（最大10秒）。起動できたら true
    @discardableResult
    func start() async -> Bool {
        if await check() { return true }
        guard !starting, let path = Self.commandPath() else { return false }
        starting = true
        defer { starting = false }
        Log.write("search: starting")
        // 裏で動かし続ける（このアプリを閉じても残る）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup '\(path)' -b 127.0.0.1 -p 8888 > /tmp/rustxng.log 2>&1 &"]
        try? process.run()
        process.waitUntilExit()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await check() {
                Log.write("search: started")
                return true
            }
        }
        Log.write("search: did not start in time")
        return false
    }

    nonisolated static func commandPath() -> String? {
        ["\(NSHomeDirectory())/.local/bin/rustxng", "/opt/homebrew/bin/rustxng", "/usr/local/bin/rustxng"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var isInstalled: Bool { commandPath() != nil }

    /// 検索して、上位の結果と、上から3件のページ本文を返す
    func search(query: String) async throws -> String {
        var components = URLComponents(string: "\(host)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "language", value: "ja"),
            URLQueryItem(name: "include_raw_content", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Tools.ToolError(message: "検索に失敗しました（HTTP \(http.statusCode)）")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let results = (obj["results"] as? [[String: Any]] ?? []).prefix(5)
        guard !results.isEmpty else { return "検索結果がありませんでした" }

        var out: [String] = []
        for (i, r) in results.enumerated() {
            let title = r["title"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            let snippet = (r["content"] as? String ?? "").prefix(300)
            var block = "[\(i + 1)] \(title)\n\(url)\n\(snippet)"
            // 本文は長いので、上の3件だけ、頭の部分を渡す（HTML のまま来ることがあるので文字だけにする）
            if i < 3, let raw = r["raw_content"] as? String, !raw.isEmpty {
                let text = raw.contains("<") ? WebTools.htmlToText(raw) : raw
                block += "\n本文: \(text.prefix(1200))"
            }
            out.append(block)
        }
        return out.joined(separator: "\n\n")
    }
}
