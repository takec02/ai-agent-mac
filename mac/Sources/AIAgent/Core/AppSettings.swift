import Foundation
import Observation
import Security
import ServiceManagement

enum DisplayMode: String, CaseIterable, Identifiable {
    case window, menuBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .menuBar: "メニューバーのみ"
        case .window: "ウィンドウ＋Dock"
        }
    }
}

enum AgentGender: String, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var label: String { self == .male ? "男性" : "女性" }
    /// 初回設定での名前の初期値（猿飛佐助／巴御前より）
    var defaultName: String { self == .male ? "サスケ" : "トモエ" }
}

enum BackendKind: String, CaseIterable, Identifiable {
    case local, claude, gpt, gemini
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: "ローカル (Ollama)"
        case .claude: "Claude"
        case .gpt: "GPT"
        case .gemini: "Gemini"
        }
    }
    var shortLabel: String {
        switch self {
        case .local: "ローカル"
        case .claude: "Claude"
        case .gpt: "GPT"
        case .gemini: "Gemini"
        }
    }
    /// 音声で「〇〇に切り替えて」と言われたときに照合する表記
    var spokenAliases: [String] {
        switch self {
        case .local: ["ローカル", "オラマ", "ollama", "local"]
        case .claude: ["クロード", "claude"]
        case .gpt: ["gpt", "ジーピーティー", "チャットgpt", "openai"]
        case .gemini: ["ジェミニ", "gemini"]
        }
    }
    var keychainAccount: String? {
        switch self {
        case .local: nil
        case .claude: "anthropic"
        case .gpt: "openai"
        case .gemini: "gemini"
        }
    }
}

/// UserDefaults に保存される設定。API キーだけはキーチェーンに保存する。
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var agentName: String { didSet { d.set(agentName, forKey: "agentName") } }
    /// 呼びかけの言葉。空なら名前を使う
    var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
    var wakeAliases: String { didSet { d.set(wakeAliases, forKey: "wakeAliases") } }
    /// 呼びかけの形（名前だけ／名前のあと／名前の前／どちらでも）
    var wakeStyle: WakeStyle { didSet { d.set(wakeStyle.rawValue, forKey: "wakeStyle") } }
    /// 名前のあとに付ける言葉（カンマ区切り）
    var wakeCallWords: String { didSet { d.set(wakeCallWords, forKey: "wakeCallWords") } }
    /// 名前の前に付ける言葉（カンマ区切り）
    var wakePrefixWords: String { didSet { d.set(wakePrefixWords, forKey: "wakePrefixWords") } }
    /// ユーザーの呼ばれ方（例: あなた、あるじ、殿）
    var userTitle: String { didSet { d.set(userTitle, forKey: "userTitle") } }
    /// 呼ばれ方に付ける敬称（空ならなし）
    var userHonorific: String { didSet { d.set(userHonorific, forKey: "userHonorific") } }
    static let honorifics = ["", "様", "さん", "殿", "くん", "ちゃん"]
    var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: "displayMode") } }
    var backend: BackendKind { didSet { d.set(backend.rawValue, forKey: "backend") } }
    var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ollamaModel") } }
    /// 予定を入れる前に重なりを調べるカレンダー（ID をカンマ区切り。空なら主カレンダーだけ）
    var conflictCalendars: String { didSet { d.set(conflictCalendars, forKey: "conflictCalendars") } }

    /// 読み上げ中に「ストップ」と言って止められるようにする
    var stopByVoice: Bool { didSet { d.set(stopByVoice, forKey: "stopByVoice") } }

    /// 絵を作ってもらうサーバー（社内の Mac など）の URL
    var imageServer: String { didSet { d.set(imageServer, forKey: "imageServer") } }

    /// 通訳するときの相手の言語（音声認識の識別子。既定は英語）
    var interpreterLanguage: String { didSet { d.set(interpreterLanguage, forKey: "interpreterLanguage") } }
    /// 翻訳を AI にさせる（オフなら macOS 内蔵の翻訳。内蔵が使えないときは自動で AI になる）
    var interpreterUseAI: Bool { didSet { d.set(interpreterUseAI, forKey: "interpreterUseAI") } }
    /// 訳した言葉を読み上げる（オフなら画面に出すだけ）
    var interpreterSpeak: Bool { didSet { d.set(interpreterSpeak, forKey: "interpreterSpeak") } }

    /// ユーザーが自由に書ける指示（毎回の指示文に入れる）
    var personalPrompt: String { didSet { d.set(personalPrompt, forKey: "personalPrompt") } }

    /// 静かな時間帯（この間は定期実行が声を出さず、通知だけにする）
    var quietFromHour: Int { didSet { d.set(quietFromHour, forKey: "quietFromHour") } }
    var quietToHour: Int { didSet { d.set(quietToHour, forKey: "quietToHour") } }

    /// ローカル AI が一度に扱える文脈の広さ（トークン数）。写真を渡すと多く使う
    var ollamaContext: Int { didSet { d.set(ollamaContext, forKey: "ollamaContext") } }

    /// 写真を見て説明してもらうモデル（空なら、入っている画像対応モデルを自動で探す）
    var visionModel: String {
        didSet {
            d.set(visionModel, forKey: "visionModel")
            VisionDescriber.reset()
        }
    }
    var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    var gptModel: String { didSet { d.set(gptModel, forKey: "gptModel") } }
    var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    var agentGender: AgentGender { didSet { d.set(agentGender.rawValue, forKey: "agentGender") } }
    var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    var followupSeconds: Double { didSet { d.set(followupSeconds, forKey: "followupSeconds") } }
    var chime: Bool { didSet { d.set(chime, forKey: "chime") } }

    private init() {
        agentName = d.string(forKey: "agentName") ?? ""
        wakeWord = d.string(forKey: "wakeWord") ?? ""
        wakeAliases = d.string(forKey: "wakeAliases") ?? ""
        wakeStyle = WakeStyle(rawValue: d.string(forKey: "wakeStyle") ?? "") ?? .after
        wakeCallWords = d.string(forKey: "wakeCallWords") ?? "応えて, 答えて, こたえて"
        wakePrefixWords = d.string(forKey: "wakePrefixWords") ?? "ヘイ, おい, ねえ, OK"
        userTitle = d.string(forKey: "userTitle") ?? "あなた"
        userHonorific = d.string(forKey: "userHonorific") ?? ""
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .window
        backend = BackendKind(rawValue: d.string(forKey: "backend") ?? "") ?? .local
        // 画像も道具も使える qwen3-vl に一本化した（qwen3:8b は画像を読めない）
        let savedModel = d.string(forKey: "ollamaModel")
        ollamaModel = (savedModel == nil || savedModel == "qwen3:8b") ? "qwen3-vl:8b-instruct" : savedModel!
        ollamaContext = d.object(forKey: "ollamaContext") as? Int ?? 16384
        visionModel = d.string(forKey: "visionModel") ?? ""
        conflictCalendars = d.string(forKey: "conflictCalendars") ?? ""
        stopByVoice = d.object(forKey: "stopByVoice") as? Bool ?? true
        imageServer = d.string(forKey: "imageServer") ?? ""
        interpreterLanguage = d.string(forKey: "interpreterLanguage") ?? "en-US"
        interpreterUseAI = d.object(forKey: "interpreterUseAI") as? Bool ?? false
        interpreterSpeak = d.object(forKey: "interpreterSpeak") as? Bool ?? true
        personalPrompt = d.string(forKey: "personalPrompt") ?? ""
        quietFromHour = d.object(forKey: "quietFromHour") as? Int ?? 22
        quietToHour = d.object(forKey: "quietToHour") as? Int ?? 7
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-opus-5"
        gptModel = d.string(forKey: "gptModel") ?? "gpt-5-mini"
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-2.5-flash"
        agentGender = AgentGender(rawValue: d.string(forKey: "agentGender") ?? "") ?? .male
        voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        followupSeconds = d.object(forKey: "followupSeconds") as? Double ?? 180
        chime = d.object(forKey: "chime") as? Bool ?? true
    }

    /// 実際にユーザーを呼ぶときの言い方（呼ばれ方＋敬称）
    var userAddress: String {
        let t = userTitle.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty ? "あなた" : t) + userHonorific
    }

    var isNamed: Bool { !agentName.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 実際に使うウェイクワード（未設定なら名前）
    var effectiveWakeWord: String {
        let w = wakeWord.trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? agentName : w
    }

    /// 今が静かな時間帯か（22時〜7時のように日をまたぐ指定にも対応）
    var isQuietNow: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        guard quietFromHour != quietToHour else { return false }
        return quietFromHour < quietToHour ? (h >= quietFromHour && h < quietToHour) : (h >= quietFromHour || h < quietToHour)
    }

    /// 設定した言葉の一覧（カンマ・読点区切り）
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { ",、，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var callWordList: [String] { Self.words(wakeCallWords) }
    /// 重なりを調べるカレンダー（空なら主カレンダーだけ）
    var conflictCalendarList: [String] {
        let list = Self.words(conflictCalendars)
        return list.isEmpty ? ["primary"] : list
    }
    var prefixWordList: [String] { Self.words(wakePrefixWords) }

    /// 画面に出す呼びかけの例（「サスケ、応えて」）
    var wakeExample: String {
        let w = effectiveWakeWord
        guard !WakeMatcher.hasCallWord(w, call: callWordList, prefix: prefixWordList) else { return w }
        switch wakeStyle {
        case .nameOnly: return w
        case .after, .both: return callWordList.first.map { "\(w)、\($0)" } ?? w
        case .before: return prefixWordList.first.map { "\($0)、\(w)" } ?? w
        }
    }

    /// 反応する表記の一覧（ウェイクワード＋別表記）。これ以外の言葉には反応しない
    var wakeWords: [String] {
        let extra = wakeAliases.split(whereSeparator: { ",、，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return ([effectiveWakeWord] + extra).filter { !$0.isEmpty }
    }

    func model(for kind: BackendKind) -> String {
        switch kind {
        case .local: ollamaModel
        case .claude: claudeModel
        case .gpt: gptModel
        case .gemini: geminiModel
        }
    }

    // MARK: ログイン時に起動

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launchAtLogin: \(error)")
            }
        }
    }
}

/// 呼びかけの形
enum WakeStyle: String, CaseIterable, Identifiable {
    case nameOnly, after, before, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nameOnly: "名前だけ（例: サスケ）"
        case .after: "名前のあとに言葉を付ける（例: サスケ、応えて）"
        case .before: "名前の前に言葉を付ける（例: ヘイ、サスケ）"
        case .both: "どちらでもよい"
        }
    }
}

enum Keychain {
    private static let service = "io.github.takec02.aiagent"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
