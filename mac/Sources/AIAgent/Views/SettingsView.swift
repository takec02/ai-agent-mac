import AVFoundation
import SwiftUI
import Translation

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "person.crop.circle") }
            AISettings().tabItem { Label("AI", systemImage: "brain") }
            VoiceSettings().tabItem { Label("声", systemImage: "speaker.wave.2") }
            WatchSettings().tabItem { Label("お知らせ", systemImage: "bell") }
            MemorySettings().tabItem { Label("記憶", systemImage: "brain.head.profile") }
            InterpreterSettings().tabItem { Label("通訳", systemImage: "globe") }
            CalendarSettings().tabItem { Label("予定・提出物", systemImage: "calendar") }
            IntegrationSettings().tabItem { Label("連携", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 520, height: 580)
        .padding(.vertical, 8)
        // 設定画面のすべての入力欄に枠を付ける（グループ表示のフォームでは、既定だと入力欄が見えないため）
        .textFieldStyle(.roundedBorder)
    }
}

private struct GeneralSettings: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("エージェント") {
                LabeledContent("名前") {
                    HStack {
                        TextField("", text: $name).labelsHidden()
                        Button("変更") {
                            s.agentName = name.trimmingCharacters(in: .whitespaces)
                            agent.wakeWordsChanged()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == s.agentName)
                    }
                }
                TextField("ウェイクワード", text: $s.wakeWord, prompt: Text("空欄なら名前（\(s.agentName)）"))
                    .onSubmit { agent.wakeWordsChanged() }
                TextField("ウェイクワードの別表記", text: $s.wakeAliases, prompt: Text("例: サスケ, 佐助"))
                    .onSubmit { agent.wakeWordsChanged() }
                Picker("呼びかけの形", selection: $s.wakeStyle) {
                    ForEach(WakeStyle.allCases) { Text($0.label).tag($0) }
                }
                if s.wakeStyle == .after || s.wakeStyle == .both {
                    TextField("名前のあとに付ける言葉", text: $s.wakeCallWords, prompt: Text("例: 応えて, 答えて"))
                }
                if s.wakeStyle == .before || s.wakeStyle == .both {
                    TextField("名前の前に付ける言葉", text: $s.wakePrefixWords, prompt: Text("例: ヘイ, おい, ねえ"))
                }
                Text(s.wakeStyle == .nameOnly
                     ? "「\(s.effectiveWakeWord)」と呼ぶだけで反応します。呼びかけの言葉を付ける形にすると、周りの会話やテレビへの誤反応が減ります。"
                     : "「\(s.wakeExample)」のように呼びかけたときだけ反応します。言葉は複数をカンマ区切りで書けます。聞き取られにくいときは、読みや別の書き方を別表記に追加してください。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("あなたの呼ばれ方", text: $s.userTitle, prompt: Text("例: あなた、あるじ、殿"))
                Picker("敬称", selection: $s.userHonorific) {
                    ForEach(AppSettings.honorifics, id: \.self) { Text($0.isEmpty ? "なし" : $0).tag($0) }
                }
                Text("「\(s.userAddress)」と呼ばれます。").font(.caption).foregroundStyle(.secondary)
            }
            Section("動作") {
                Picker("表示方法", selection: $s.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.displayMode) { _, mode in
                    AppDelegate.applyDisplayMode(mode)
                    if mode == .window { openWindow(id: "main") }
                }
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in s.launchAtLogin = v }
                Toggle("呼びかけに反応したら効果音を鳴らす", isOn: $s.chime)
                Picker("呼びかけのあと、続けて話せる時間", selection: $s.followupSeconds) {
                    Text("オフ（毎回呼びかける）").tag(0.0)
                    Text("30秒").tag(30.0)
                    Text("1分").tag(60.0)
                    Text("3分").tag(180.0)
                    Text("5分").tag(300.0)
                    Text("10分").tag(600.0)
                }
                Text("最後に話してからこの時間は、名前を呼ばずに話しかけられます。「ありがとう」「おやすみ」で待機に戻ります。この間は、周りの会話やテレビの声も拾うことがあります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = agent.settings.agentName
            launchAtLogin = agent.settings.launchAtLogin
        }
    }
}

private struct AISettings: View {
    @Environment(AgentController.self) private var agent
    @State private var tavilyUsage: WebTools.Usage?
    @State private var usageError: String?

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section {
                Picker("使う AI", selection: $s.backend) {
                    ForEach(BackendKind.allCases) { Text($0.label).tag($0) }
                }
                Text("会話中に「クロードに切り替えて」のように話しても変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ローカル (Ollama) — 無料") {
                TextField("モデル", text: $s.ollamaModel)
                Picker("一度に扱える量", selection: $s.ollamaContext) {
                    Text("標準（16,384）").tag(16384)
                    Text("広め（32,768）― 長い会話や写真が多いとき").tag(32768)
                    Text("最小（8,192）― メモリが少ないとき").tag(8192)
                }
                TextField("写真を見るモデル", text: $s.visionModel, prompt: Text("空欄なら自動（gemma3 など、画像を読めるモデルを探す）"))
                Text("会話に使うモデルが画像を読めないとき、写真だけをこのモデルに見せて説明してもらいます。写真は Mac の外に出ません。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Ollama をダウンロード", destination: URL(string: "https://ollama.com/download")!)
            }
            Section("Claude — 従量課金") {
                TextField("モデル", text: $s.claudeModel)
                APIKeyField(account: "anthropic", placeholder: "sk-ant-… を貼り付け", link: "https://console.anthropic.com/settings/keys")
            }
            Section("GPT — 従量課金") {
                TextField("モデル", text: $s.gptModel)
                APIKeyField(account: "openai", placeholder: "sk-… を貼り付け", link: "https://platform.openai.com/api-keys")
            }
            Section("Gemini — 無料枠あり") {
                TextField("モデル", text: $s.geminiModel)
                APIKeyField(account: "gemini", placeholder: "AIza… を貼り付け", link: "https://aistudio.google.com/apikey")
            }
            Section {
                APIKeyField(account: "tavily", placeholder: "tvly-… を貼り付け", link: "https://app.tavily.com") {
                    Task { await refreshUsage() }
                }
                LabeledContent("今月の使用量") {
                    HStack(spacing: 8) {
                        if let u = tavilyUsage {
                            ProgressView(value: Double(min(u.used, u.limit)), total: Double(max(u.limit, 1)))
                                .frame(width: 120)
                                .tint(u.used >= u.limit ? .red : u.used * 10 >= u.limit * 8 ? .orange : .accentColor)
                            Text("\(u.used) / \(u.limit) 回").monospacedDigit()
                        } else {
                            Text(usageError ?? "—").foregroundStyle(.secondary)
                        }
                        Button { Task { await refreshUsage() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("使用量を更新")
                    }
                }
            } header: {
                Text("Web 検索（Tavily）— 月1,000回まで無料")
            } footer: {
                Text("ローカル・GPT・Gemini のときに使います。Claude のときは Claude 内蔵の Web 検索（1,000回あたり約10ドル）を使います。無料枠を使い切ると、翌月の枠が回復するまで検索できません（その間はブラウザで開く検索を提案します）。")
            }
            Section {
                Text("API キーは入力するとすぐに Mac のキーチェーンに保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshUsage() }
    }

    private func refreshUsage() async {
        do {
            tavilyUsage = try await WebTools.usage()
            usageError = nil
        } catch {
            tavilyUsage = nil
            usageError = (error as? Tools.ToolError)?.message ?? "取得できません"
        }
    }
}

/// API キーの入力欄。枠付きで、登録済みかどうかと末尾4文字を表示し、入力するとすぐ保存する
private struct APIKeyField: View {
    let account: String
    let placeholder: String
    let link: String
    var onSaved: (() -> Void)?
    @State private var value = ""
    @State private var reveal = false
    @State private var loaded = false

    init(account: String, placeholder: String, link: String, onSaved: (() -> Void)? = nil) {
        self.account = account
        self.placeholder = placeholder
        self.link = link
        self.onSaved = onSaved
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API キー")
                Spacer()
                if trimmed.isEmpty {
                    Label("未登録", systemImage: "circle.dashed").foregroundStyle(.secondary)
                } else {
                    Label("登録済み（…\(trimmed.suffix(4))）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Link("キーを取得", destination: URL(string: link)!)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField("", text: $value, prompt: Text(placeholder))
                    } else {
                        SecureField("", text: $value, prompt: Text(placeholder))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .labelsHidden()
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(reveal ? "隠す" : "表示する")
                if !trimmed.isEmpty {
                    Button { value = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("キーを削除")
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            value = Keychain.get(account) ?? ""
            loaded = true
        }
        .onChange(of: value) {
            guard loaded else { return }
            Keychain.set(trimmed, for: account)
            onSaved?()
        }
    }
}

private struct VoiceSettings: View {
    @Environment(AgentController.self) private var agent
    @State private var tester = Speaker()

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section {
                Picker("性別", selection: $s.agentGender) {
                    ForEach(AgentGender.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: s.agentGender) { _, g in
                    // 選んでいた声が別の性別なら、自動選択に戻す
                    if let v = Speaker.japaneseVoices.first(where: { $0.identifier == s.voiceIdentifier }), Speaker.gender(of: v) != g {
                        s.voiceIdentifier = ""
                    }
                }
                Picker("声", selection: $s.voiceIdentifier) {
                    Text("自動（最も自然な\(s.agentGender.label)の声）").tag("")
                    ForEach(Speaker.voices(for: s.agentGender), id: \.identifier) { v in
                        Text("\(v.name)\(qualityLabel(v.quality))").tag(v.identifier)
                    }
                }
                LabeledContent("話す速さ") {
                    Slider(value: $s.speechRate, in: 0.4...0.65)
                }
                HStack {
                    Spacer()
                    Button("試しに聞く") {
                        tester.voiceIdentifier = s.voiceIdentifier
                        tester.gender = s.agentGender
                        tester.rate = Float(s.speechRate)
                        tester.stop()
                        tester.say("はじめまして。\(s.agentName)です。ご用件をどうぞ。")
                    }
                }
            } footer: {
                Text("より自然な声は「システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 → 声を管理」から追加すると選べるようになります。男性なら Otoya、女性なら Kyoko の「拡張」や「プレミアム」がおすすめです。")
            }
        }
        .formStyle(.grouped)
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "（プレミアム）"
        case .enhanced: "（拡張）"
        default: ""
        }
    }
}

// MARK: お知らせ（自分から確かめて知らせる）

private struct WatchSettings: View {
    @Environment(AgentController.self) private var agent
    @State private var editing: WatchRule?

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("見張り") {
                if agent.watcher.rules.isEmpty {
                    Text("まだ何もありません。「追加」で作れます。").foregroundStyle(.secondary)
                }
                ForEach(agent.watcher.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { on in
                                var r = rule
                                r.enabled = on
                                agent.watcher.update(r)
                            })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text("\(rule.scheduleLabel)\(rule.lastRun.map { " ・ 最後に確認 " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("編集") { editing = rule }
                        Button(role: .destructive) { agent.watcher.remove(rule) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("追加") { editing = agent.watcher.addNew() }
                Text("決めた時刻や間隔で、頼んだことを\(agent.settings.agentName)が自分で確かめます。知らせることが無ければ黙ります。話している最中や会議の記録中は行いません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("静かな時間") {
                HStack {
                    Picker("開始", selection: $s.quietFromHour) { ForEach(0..<24) { Text("\($0)時").tag($0) } }
                    Picker("終了", selection: $s.quietToHour) { ForEach(0..<24) { Text("\($0)時").tag($0) } }
                }
                Text("この時間帯は声を出さず、通知だけにします。開始と終了を同じにすると、いつでも声を出します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .sheet(item: $editing) { rule in WatchRuleSheet(rule: rule) { agent.watcher.update($0) } }
    }
}

private struct WatchRuleSheet: View {
    enum Timing: Hashable { case daily, monthly, interval }

    @State var rule: WatchRule
    let onSave: (WatchRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timing: Timing

    init(rule: WatchRule, onSave: @escaping (WatchRule) -> Void) {
        _rule = State(initialValue: rule)
        _timing = State(initialValue: rule.everyMinutes != nil ? .interval : (rule.dayOfMonth != nil ? .monthly : .daily))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("見張りの設定").font(.headline)
            Form {
                TextField("名前", text: $rule.name, prompt: Text("例: 朝の読み上げ"))
                Picker("いつ", selection: $timing) {
                    Text("毎日 決まった時刻").tag(Timing.daily)
                    Text("毎月 決まった日").tag(Timing.monthly)
                    Text("一定の間隔ごと").tag(Timing.interval)
                }
                .pickerStyle(.radioGroup)
                if timing == .monthly {
                    Picker("日", selection: Binding(get: { rule.dayOfMonth ?? 25 }, set: { rule.dayOfMonth = $0 })) {
                        ForEach(1..<29) { Text("\($0)日").tag($0) }
                        Text("月末").tag(31)
                    }
                }
                if timing == .interval {
                    Picker("間隔", selection: Binding(get: { rule.everyMinutes ?? 30 }, set: { rule.everyMinutes = $0 })) {
                        ForEach([5, 10, 15, 30, 60, 120, 180, 360], id: \.self) {
                            Text($0 % 60 == 0 && $0 >= 60 ? "\($0 / 60)時間ごと" : "\($0)分ごと").tag($0)
                        }
                    }
                } else {
                    HStack {
                        Picker("時刻", selection: $rule.hour) { ForEach(0..<24) { Text("\($0)時").tag($0) } }
                        Picker("", selection: $rule.minute) { ForEach([0, 15, 30, 45], id: \.self) { Text("\($0)分").tag($0) } }
                            .labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("やってもらうこと")
                    TextEditor(text: $rule.prompt)
                        .frame(height: 90)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.4)))
                    Text("例: 未読のメールを確認して、すぐ返事が要るものだけを挙げて。無ければ、何も言わず静かにしている。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("声で知らせる", isOn: $rule.speak)
                Toggle("通知を出す", isOn: $rule.notify)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("やめる") { dismiss() }
                Button("保存") {
                    switch timing {
                    case .daily:
                        rule.everyMinutes = nil
                        rule.dayOfMonth = nil
                    case .monthly:
                        rule.everyMinutes = nil
                        if rule.dayOfMonth == nil { rule.dayOfMonth = 25 }
                    case .interval:
                        rule.dayOfMonth = nil
                        if rule.everyMinutes == nil { rule.everyMinutes = 30 }
                    }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 480)
        .textFieldStyle(.roundedBorder)
    }
}

// MARK: 記憶とパーソナル指示

private struct MemorySettings: View {
    @Environment(AgentController.self) private var agent
    @State private var store = MemoryStore.shared
    @State private var newText = ""
    @State private var confirmClear = false

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("あなたからの指示") {
                TextEditor(text: $s.personalPrompt)
                    .frame(height: 110)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.4)))
                Text("ここに書いたことは毎回の指示に入り、最優先で守られます。例:「私は営業職。専門用語は噛み砕いて話して」「結論から先に言って」「敬語は控えめに」")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("覚えていること（\(store.items.count)件）") {
                HStack {
                    TextField("覚えさせたいこと", text: $newText, prompt: Text("例: 山田さんは A 社の担当"))
                    Button("追加") {
                        store.remember(newText)
                        newText = ""
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if store.items.isEmpty {
                    Text("まだ何も覚えていません。会話の中で「覚えておいて」と言うか、ここで足せます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("", text: Binding(
                                get: { item.text },
                                set: { text in
                                    var m = item
                                    m.text = text
                                    store.update(m)
                                }))
                            Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Toggle("ローカルのみ", isOn: Binding(
                            get: { item.localOnly },
                            set: { on in
                                var m = item
                                m.localOnly = on
                                store.update(m)
                            }))
                            .toggleStyle(.checkbox)
                            .help("オンにすると、AI がローカルのときだけ使います。クラウドの AI には渡しません")
                        Button(role: .destructive) { store.remove(item) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if !store.items.isEmpty {
                    Button("すべて消す", role: .destructive) { confirmClear = true }
                }
                Text("覚えていることは毎回の指示に入り、判断に使われます。保存先は Mac の中（\(MemoryStore.fileURL.path)）です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .alert("覚えていることをすべて消しますか？", isPresented: $confirmClear) {
            Button("消す", role: .destructive) { store.removeAll() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("\(store.items.count)件が消えます。元に戻せません。")
        }
    }
}

// MARK: 通訳

private struct InterpreterSettings: View {
    @Environment(AgentController.self) private var agent
    @State private var builtInReady: Bool?
    @State private var preparing = false
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("通訳") {
                Picker("相手の言語", selection: $s.interpreterLanguage) {
                    ForEach(Interpreter.languages, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: s.interpreterLanguage) { _, _ in check() }
                Picker("訳す担当", selection: $s.interpreterUseAI) {
                    Text("macOS 内蔵の翻訳（速い）").tag(false)
                    Text("AI（文脈をふまえる。少し遅い）").tag(true)
                }
                Toggle("訳した言葉を読み上げる", isOn: $s.interpreterSpeak)
                Text("画面下の地球のボタンで始めます。通訳の間は呼びかけに反応せず、聞こえた言葉を日本語と\(Interpreter.label(for: s.interpreterLanguage))の間で訳します。どちらも Mac の中で処理され、外には出ません（AI をクラウドにしている場合を除く）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("内蔵翻訳の準備") {
                switch builtInReady {
                case true: Label("この言語の翻訳データは入っています", systemImage: "checkmark.circle")
                case false:
                    Label("まだ入っていません。入れると速くなります（入れるまでは AI が訳します）", systemImage: "arrow.down.circle")
                    Button(preparing ? "準備中…" : "翻訳データを入れる") {
                        preparing = true
                        configuration = TranslationSession.Configuration(
                            source: Locale.Language(identifier: "ja"),
                            target: Locale.Language(identifier: Interpreter.languageCode(s.interpreterLanguage)))
                    }
                    .disabled(preparing)
                default: ProgressView().controlSize(.small)
                }
                Text("音声を聞き取るためのデータは、通訳を最初に始めたときに自動で入ります（数十MB）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .task { check() }
        .translationTask(configuration) { session in
            // 翻訳データが無ければ、ここで macOS がダウンロードの確認を出す
            try? await session.prepareTranslation()
            preparing = false
            check()
        }
    }

    private func check() {
        builtInReady = nil
        let language = agent.settings.interpreterLanguage
        Task { builtInReady = await Interpreter.builtInReady(language) }
    }
}

// MARK: 予定（重なりの確認）

private struct CalendarSettings: View {
    @Environment(AgentController.self) private var agent
    @State private var calendars: [(id: String, name: String)] = []
    @State private var loading = true

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("予定を入れる前に、重なりを確かめるカレンダー") {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("カレンダーを読み込んでいます…") }
                } else if calendars.isEmpty {
                    Text("カレンダーを取得できませんでした。設定 → 連携 で Google がつながっているか確かめてください。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendars, id: \.id) { calendar in
                        Toggle(calendar.name, isOn: binding(for: calendar.id))
                    }
                }
                Text("選んだカレンダーに予定が入っている時間に、新しい予定を入れようとすると、「〇〇が入っていますが、よろしいですか？」と確認します。終日の予定（祝日など）は数えません。何も選ばないときは、主カレンダーだけを見ます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            calendars = await MCPManager.shared.googleCalendars()
            // 主カレンダーは一覧に出ないことがあるので、先頭に足しておく
            if !calendars.contains(where: { $0.id == "primary" }) {
                calendars.insert((id: "primary", name: "自分のカレンダー（主）"), at: 0)
            }
            loading = false
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        let s = agent.settings
        return Binding(
            get: { s.conflictCalendarList.contains(id) },
            set: { on in
                var list = AppSettings.words(s.conflictCalendars)
                if list.isEmpty { list = ["primary"] }
                if on {
                    if !list.contains(id) { list.append(id) }
                } else {
                    list.removeAll { $0 == id }
                }
                s.conflictCalendars = list.joined(separator: ", ")
            })
    }
}
