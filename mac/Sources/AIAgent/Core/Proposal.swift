import AppKit
import Foundation

/// 提案書の中身（スライド1枚ずつ）
struct ProposalDeck {
    struct Slide {
        var heading: String
        var bullets: [String]
    }
    var title: String
    var subtitle: String
    var slides: [Slide]
}

/// 提案書を出す形
enum ProposalFormat: String, CaseIterable, Identifiable {
    case pptx, googleSlides, pdf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pptx: "PowerPoint"
        case .googleSlides: "Google スライド"
        case .pdf: "PDF"
        }
    }
}

/// 会議の話から提案書を作る。
/// 会議中は数分おきに「提案につながる話が出たか」を AI に見てもらい、出ていたらボタンを光らせる
@MainActor
@Observable
final class ProposalMaker {
    static let shared = ProposalMaker()

    /// 提案できそうな話が出ている（ボタンを光らせる）
    private(set) var suggested = false
    /// なぜ提案できそうか（ボタンの説明に出す）
    private(set) var reason = ""
    private(set) var making = false
    private(set) var progress = ""

    static let folder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/AIエージェント/提案書")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: 提案のチャンスを見張る

    private var watchTask: Task<Void, Never>?
    private var checkedLength = 0

    /// 会議の記録を始めたら呼ぶ。3分おきに、新しく話が増えていれば見てもらう
    func startWatching(transcript: @escaping @MainActor () -> String) {
        stopWatching()
        checkedLength = 0
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard let self, !Task.isCancelled, !self.suggested, !self.making else { continue }
                let text = transcript()
                guard text.count - self.checkedLength >= 300 else { continue }
                self.checkedLength = text.count
                await self.checkOpportunity(text)
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        suggested = false
        reason = ""
    }

    private func checkOpportunity(_ transcript: String) async {
        let system = """
        あなたは営業の同席者です。入力は進行中の会議の文字起こし（音声認識なので誤字を含む）です。
        「自分」はこちら側、「相手」はお客さま側です。
        相手の課題・困りごと・要望・予算・検討中のことなど、こちらから提案書を出せそうな話が出ているかを判断してください。
        次の JSON だけを返してください: {"suggest": true または false, "reason": "提案できそうな理由を20字以内で"}
        """
        do {
            let answer = try await PlainLLM.ask(system: system, user: String(transcript.suffix(6000)), json: true)
            guard let obj = PlainLLM.jsonObject(answer) else { return }
            if obj["suggest"] as? Bool == true {
                suggested = true
                reason = (obj["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                Log.write("proposal: suggested (\(reason))")
            }
        } catch {
            Log.write("proposal check failed: \(error.localizedDescription)")
        }
    }

    // MARK: 作る

    /// 会議の話から提案書を作り、保存した場所（Google スライドならその URL）を返す
    func make(transcript: String, format: ProposalFormat) async throws -> URL {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Tools.ToolError(message: "まだ会議の話が記録されていません")
        }
        making = true
        defer { making = false; progress = "" }
        let talk = String(transcript.suffix(12_000))
        let settings = AppSettings.shared

        // 1. 何の提案か、何を調べるとよいかを決める
        progress = "話を整理しています"
        let plan = try await PlainLLM.ask(system: """
        入力は会議の文字起こし（音声認識なので誤字を含む）です。「自分」はこちら側、「相手」はお客さま側です。
        次の JSON だけを返してください:
        {"topic": "提案の主題を20字以内で", "customer": "相手の会社名や部署（分からなければ空）", "search": "提案に役立つ情報を Web で探すための検索語（日本語、要らなければ空）"}
        """, user: talk, json: true)
        let planObj = PlainLLM.jsonObject(plan) ?? [:]
        let topic = planObj["topic"] as? String ?? ""
        let search = (planObj["search"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. 材料を集める（自社の情報・登録した資料・Web）
        var materials: [String] = []
        let company = settings.companyProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty { materials.append("【自社の情報】\n\(company)") }
        progress = "資料を探しています"
        let docs = Library.shared.context(for: topic.isEmpty ? String(talk.suffix(500)) : topic, limit: 4)
        if !docs.isEmpty { materials.append("【登録した資料から】\n\(docs)") }
        if settings.proposalUseWeb, !search.isEmpty {
            progress = "Web で調べています"
            if let found = try? await WebTools.search(query: search) {
                materials.append("【Web 検索「\(search)」の結果】\n\(found.prefix(4000))")
            }
        }

        // 3. 提案書の中身を書く
        progress = "提案書を書いています"
        let deck = try await writeDeck(talk: talk, materials: materials.joined(separator: "\n\n"))

        // 4. 選んだ形にする
        progress = "\(format.label)にしています"
        let base = Self.folder.appendingPathComponent(Self.fileName(deck.title))
        switch format {
        case .pdf:
            let url = base.appendingPathExtension("pdf")
            try ProposalRenderer.pdf(deck, to: url)
            return url
        case .pptx:
            let url = base.appendingPathExtension("pptx")
            try ProposalRenderer.pptx(deck, to: url)
            return url
        case .googleSlides:
            let url = base.appendingPathExtension("pptx")
            try ProposalRenderer.pptx(deck, to: url)
            progress = "Google ドライブに上げています"
            return try await GoogleDriveUpload.asSlides(url, name: deck.title)
        }
    }

    private func writeDeck(talk: String, materials: String) async throws -> ProposalDeck {
        // 書き方の指示（設定で変えられる）の前後に、動くのに欠かせない決まりごとを付ける
        let custom = AppSettings.shared.proposalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
        会議の文字起こしと材料をもとに、相手への提案書を日本語で作ってください。
        文字起こしは音声認識なので誤字を含みます。「自分」はこちら側、「相手」はお客さま側です。
        今日は \(Self.today) です。表紙の日付にはこれを使ってください。
        材料の【自社の情報】がこちらの会社です。

        \(custom.isEmpty ? Self.defaultPrompt : custom)

        次の JSON だけを返してください:
        {"title": "提案書の題名", "subtitle": "相手の会社名と日付など", "slides": [{"heading": "見出し", "bullets": ["項目", "項目"]}]}
        """
        let user = "## 会議の文字起こし\n\(talk)\n\n## 材料\n\(materials.isEmpty ? "なし" : materials)"
        for attempt in 1...2 {
            let answer = try await PlainLLM.ask(system: system, user: user, json: true)
            if let deck = Self.parse(answer), !deck.slides.isEmpty {
                Log.write("proposal: \(deck.slides.count) slides (attempt \(attempt))")
                return deck
            }
            Log.write("proposal: unreadable answer (attempt \(attempt)): \(answer.prefix(200))")
        }
        throw Tools.ToolError(message: "提案書の中身を作れませんでした。AI を切り替えるか、もう一度お試しください")
    }

    /// 書き方の指示の既定（設定 → 提案書 で書き換えられる）
    static let defaultPrompt = """
    あなたは提案書を書く担当です。
    会議と材料に出てこない数字（件数・日数・割合・金額・効果の見込み）や実績は、一つも書かないでください。分からないところは「要確認」と書きます。
    構成の目安: 表紙の次に、現状と課題 → ご提案の内容 → 期待できる効果 → 進め方・スケジュール → 次のステップ。5〜8枚。
    1枚の箇条書きは3〜5項目、1項目は40字以内。
    """

    private static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: Date())
    }

    static func parse(_ text: String) -> ProposalDeck? {
        guard let obj = PlainLLM.jsonObject(text) else { return nil }
        let slides = (obj["slides"] as? [[String: Any]] ?? []).compactMap { s -> ProposalDeck.Slide? in
            let heading = (s["heading"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bullets = (s["bullets"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return heading.isEmpty && bullets.isEmpty ? nil : .init(heading: heading, bullets: bullets)
        }
        let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ProposalDeck(title: title.isEmpty ? "ご提案書" : title,
                            subtitle: obj["subtitle"] as? String ?? "", slides: slides)
    }

    /// 「2026-11-14_1530_業務効率化のご提案」
    private static func fileName(_ title: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let words = title.prefix(30).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return "\(stamp.string(from: Date()))_\(words)"
    }
}
