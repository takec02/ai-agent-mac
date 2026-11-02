import Foundation

/// 気象庁の天気予報（https://www.jma.go.jp/bosai/）。政府標準利用規約に基づき、出典を明記して利用する。
enum JMAWeather {
    private struct Area: Decodable { let name: String; let parent: String? }
    private struct AreaTable: Decodable {
        let offices: [String: Area]
        let class10s: [String: Area]
        let class15s: [String: Area]
        let class20s: [String: Area]
    }

    nonisolated(unsafe) private static var cachedAreas: AreaTable?

    private static func areas() async throws -> AreaTable {
        if let a = cachedAreas { return a }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://www.jma.go.jp/bosai/common/const/area.json")!)
        guard let a = try? JSONDecoder().decode(AreaTable.self, from: data) else {
            throw Tools.ToolError(message: "気象庁の地域データを読めません。データ形式が変わった可能性があり、アプリの更新が必要です")
        }
        cachedAreas = a
        return a
    }

    /// 地名（都道府県・地方・市区町村）から (予報区の府県コード, 一次細分区域コード, 表示名) を探す
    /// 気象庁の区分に直接ない地名の読み替え（北海道は地方ごとに分かれているため札幌の地域を使う）
    private static let aliases = ["北海道": "札幌市"]

    private static func resolve(_ rawPlace: String, in t: AreaTable) -> (office: String, class10: String?, label: String)? {
        let place = aliases[rawPlace.trimmingCharacters(in: .whitespaces)] ?? rawPlace
        let q = place.replacingOccurrences(of: "[都府県市区町村]$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        // 完全一致 →「◯◯市」→「◯◯都/府/県」→ 前方一致 → 部分一致 の順で、同順位なら短い名前を優先
        func pick(_ dict: [String: Area]) -> (String, Area)? {
            func rank(_ n: String) -> Int? {
                if n == place || n == q { return 0 }
                if n == q + "市" || n.hasPrefix(q + "市") { return 1 }  // 政令市は「横浜市鶴見区」のように区ごとに分かれている
                if ["都", "府", "県", "区", "地方"].contains(where: { n == q + $0 }) { return 2 }
                if n.hasPrefix(q) { return 3 }
                if n.contains(q) { return 4 }
                return nil
            }
            return dict.compactMap { k, v in rank(v.name).map { (k, v, $0) } }
                .min { ($0.2, $0.1.name.count, $0.0) < ($1.2, $1.1.name.count, $1.0) }
                .map { ($0.0, $0.1) }
        }
        if let (code, a) = pick(t.offices) { return (code, nil, a.name) }
        if let (code, a) = pick(t.class10s), let office = a.parent { return (office, code, a.name) }
        if let (_, a) = pick(t.class20s), let c15 = a.parent, let c10 = t.class15s[c15]?.parent,
           let office = t.class10s[c10]?.parent {
            return (office, c10, "\(a.name)（\(t.class10s[c10]?.name ?? "")）")
        }
        return nil
    }

    static func forecast(place: String) async throws -> String {
        let table = try await areas()
        guard let r = resolve(place, in: table) else {
            throw Tools.ToolError(message: "「\(place)」に当たる地域が見つかりません。都道府県名か市区町村名で指定してください")
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://www.jma.go.jp/bosai/forecast/data/forecast/\(r.office).json")!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let series = root.first?["timeSeries"] as? [[String: Any]] else {
            throw Tools.ToolError(message: "気象庁の予報データを読めません。データ形式が変わった可能性があり、アプリの更新が必要です")
        }
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "ja_JP")
        dayFmt.dateFormat = "M月d日(E)"
        let iso = ISO8601DateFormatter()
        func dates(_ ts: [String: Any]) -> [Date] { (ts["timeDefines"] as? [String] ?? []).compactMap { iso.date(from: $0) } }
        func areaIndex(_ ts: [String: Any]) -> Int {
            let areas = ts["areas"] as? [[String: Any]] ?? []
            return areas.firstIndex { (($0["area"] as? [String: Any])?["code"] as? String) == r.class10 } ?? 0
        }

        var lines = ["\(r.label)の天気予報（出典: 気象庁）"]
        // 天気・風
        if series.count > 0 {
            let ts = series[0], i = areaIndex(ts)
            let area = (ts["areas"] as? [[String: Any]])?[safe: i] ?? [:]
            let weathers = area["weathers"] as? [String] ?? []
            for (d, w) in zip(dates(ts), weathers).prefix(2) {
                lines.append("\(dayFmt.string(from: d)): \(w.replacingOccurrences(of: "\u{3000}", with: " "))")
            }
        }
        // 降水確率（6時間ごと）
        if series.count > 1 {
            let ts = series[1], i = areaIndex(ts)
            let pops = ((ts["areas"] as? [[String: Any]])?[safe: i]?["pops"] as? [String]) ?? []
            let hourFmt = DateFormatter()
            hourFmt.dateFormat = "d日H時"
            let parts = zip(dates(ts), pops).map { "\(hourFmt.string(from: $0))から\($1)%" }
            if !parts.isEmpty { lines.append("降水確率: " + parts.joined(separator: "、")) }
        }
        // 気温（0時の値が最低気温、9時の値が最高気温）
        if series.count > 2 {
            let ts = series[2], i = min(areaIndex(series[0]), ((ts["areas"] as? [[String: Any]])?.count ?? 1) - 1)
            let area = (ts["areas"] as? [[String: Any]])?[safe: i] ?? [:]
            let point = (area["area"] as? [String: Any])?["name"] as? String ?? ""
            let temps = area["temps"] as? [String] ?? []
            // 日ごとに最低（0時の値）・最高（9時の値）をまとめる。早朝の発表では今日の最低の欄に最高と同じ値が入るので除く
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            var days: [(day: Date, min: String?, max: String?)] = []
            for (d, v) in zip(dates(ts), temps) {
                let day = cal.startOfDay(for: d)
                if days.last?.day != day { days.append((day, nil, nil)) }
                if cal.component(.hour, from: d) == 0 { days[days.count - 1].min = v } else { days[days.count - 1].max = v }
            }
            let parts = days.map { d -> String in
                let lo = d.min == d.max ? nil : d.min
                let items = [lo.map { "最低\($0)度" }, d.max.map { "最高\($0)度" }].compactMap { $0 }
                return "\(dayFmt.string(from: d.day))は" + items.joined(separator: "・")
            }
            if !parts.isEmpty { lines.append("予想気温（\(point)）: " + parts.joined(separator: "、")) }
        }
        return lines.joined(separator: "\n")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Web 検索（Tavily）とページの読み取り
enum WebTools {
    /// 規約で自動取得が禁止されているサイト（ブラウザで開くよう案内する）
    static let blockedHosts = ["weathernews.jp", "weathernews.com"]

    static func search(query: String) async throws -> String {
        // 自分の Mac の検索（RustXNG）が使えればそちらを使う。だめなら Tavily
        let server = SearchServer.shared
        if SearchServer.isInstalled, await server.start() {
            do {
                let result = try await server.search(query: query)
                Log.write("search: rustxng")
                return result
            } catch {
                Log.write("search: rustxng failed (\(error.localizedDescription)), falling back to tavily")
            }
        }
        guard let key = Keychain.get("tavily"), !key.isEmpty else {
            throw Tools.ToolError(message: "検索できません。RustXNG を入れるか、Tavily の API キーを登録してください（設定 → AI）")
        }
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "max_results": 5, "search_depth": "basic", "include_answer": true,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Tools.ToolError(message: tavilyError(http))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var out: [String] = []
        if let answer = obj["answer"] as? String, !answer.isEmpty { out.append("要約: \(answer)") }
        for (i, r) in (obj["results"] as? [[String: Any]] ?? []).enumerated() {
            let title = r["title"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            let content = (r["content"] as? String ?? "").prefix(600)
            out.append("[\(i + 1)] \(title)\n\(url)\n\(content)")
        }
        return out.isEmpty ? "検索結果がありませんでした" : out.joined(separator: "\n\n")
    }

    /// Tavily のエラーを、ユーザーに伝えられる形にする。AI には代わりの手段も示す
    private static func tavilyError(_ http: HTTPURLResponse) -> String {
        let fallback = "代わりに open_web_search でブラウザに検索結果を開けることを提案してください。"
        switch http.statusCode {
        case 401: return "Tavily の API キーが無効です（設定 → AI で確認）。" + fallback
        case 432: return "Tavily の今月の無料枠（1,000回）を使い切りました。翌月に回復するまで検索できません。" + fallback
        case 433: return "Tavily の従量課金の上限に達しました（Tavily のダッシュボードで上限を変更できます）。" + fallback
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").map { "約\($0)秒後に" } ?? "少し待ってから"
            return "短時間に検索しすぎたため一時的に制限されています。\(wait)もう一度試せます。"
        case 500...599: return "Tavily 側で一時的な障害が起きています。" + fallback
        default: return "検索に失敗しました（HTTP \(http.statusCode)）。" + fallback
        }
    }

    struct Usage { let used: Int; let limit: Int }

    /// 今月の使用量（プラン全体の使用回数と上限）
    static func usage() async throws -> Usage {
        guard let key = Keychain.get("tavily"), !key.isEmpty else { throw Tools.ToolError(message: "キー未登録") }
        var req = URLRequest(url: URL(string: "https://api.tavily.com/usage")!, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Tools.ToolError(message: http.statusCode == 401 ? "キーが無効です" : "取得できません（HTTP \(http.statusCode)）")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let account = obj["account"] as? [String: Any] ?? [:]
        let key_ = obj["key"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        guard let used = int(account["plan_usage"]) ?? int(key_["usage"]),
              let limit = int(account["plan_limit"]) ?? int(key_["limit"]) else {
            throw Tools.ToolError(message: "取得できません")
        }
        return Usage(used: used, limit: limit)
    }

    static func read(urlString: String) async throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            throw Tools.ToolError(message: "http または https の URL を指定してください")
        }
        if blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            throw Tools.ToolError(message: "このサイトは利用規約で自動取得が禁止されているため読めません。open_weathernews などでブラウザで開いてください")
        }
        // Mac 内部やローカルネットワークには接続しない（Web ページ経由で内部のサービスを操作されないように）
        if isPrivateHost(host) { throw Tools.ToolError(message: "ローカルネットワークのアドレスは読めません") }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh) AIAgent/0.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let final = resp.url?.host?.lowercased(), isPrivateHost(final) {
            throw Tools.ToolError(message: "ローカルネットワークのアドレスは読めません")
        }
        let raw = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        let isHTML = (resp.mimeType ?? "").contains("html") || raw.lowercased().contains("<html")
        let text = isHTML ? htmlToText(raw) : raw
        let trimmed = String(text.prefix(8000))
        return trimmed.isEmpty ? "本文を取得できませんでした" : trimmed + (text.count > 8000 ? "\n（以下省略）" : "")
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (e, c) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: "[ \\t\\u3000]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
