import AppKit
import SwiftUI
import Translation
import Speech
import Contacts
import UserNotifications

@main
struct AIAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var agent = AgentController.shared

    var body: some Scene {
        // メニューバーのアイコン（どちらの表示方法でも常に表示）
        MenuBarExtra {
            HUDView(compact: true)
                .environment(agent)
                .frame(width: 360, height: 560)
        } label: {
            MenuBarLabel().environment(agent)
        }
        .menuBarExtraStyle(.window)

        Window("AIエージェント", id: "main") {
            HUDView()
                .environment(agent)
                .frame(minWidth: 400, minHeight: 620)
                .containerBackground(Color(red: 0.02, green: 0.03, blue: 0.05), for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 460, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Window("資料", id: "library") {
            LibraryView()
                .environment(agent)
        }
        .defaultSize(width: 720, height: 480)

        Window("議事録", id: "notes") {
            NotesView()
                .environment(agent)
        }
        .defaultSize(width: 860, height: 560)

        Window("AIエージェントへようこそ", id: "onboarding") {
            OnboardingView()
                .environment(agent)
                .windowDismissBehavior(.disabled)  // 名前をつけるまで閉じられない
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(agent)
        }
    }
}

/// メニューバーのアイコン。起動時に一度だけ、初回設定かメインウィンドウを開く。
private struct MenuBarLabel: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: agent.state.symbol)
            .task {
                AppDelegate.openWindow = { openWindow(id: $0) }
                // 動作確認用の起動では、画面・マイク・あいさつを始めない
                if AppDelegate.isSelfTest { return }
                let s = agent.settings
                if !s.isNamed {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "onboarding")
                    NSApp.activate()
                } else {
                    AppDelegate.applyDisplayMode(s.displayMode)
                    if s.displayMode == .window { openWindow(id: "main") }
                    agent.startIfReady()
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindow: ((String) -> Void)?

    static var isSelfTest: Bool {
        CommandLine.arguments.contains { $0.hasSuffix("-selftest") }
    }

    /// 2つ目を起動しようとしたら、すでに動いている方を前に出して、こちらは終了する（常に1つだけ）
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isSelfTest, let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me }) {
            other.activate()
            exit(0)
        }
    }

    // 動作確認用: `AIAgent --mcp-selftest [ツール名 JSON引数]` で MCP の接続とツール呼び出しを表示して終了する
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // 動作確認用: `AIAgent --image-selftest <画像> "質問"` で、渡した画像について答えられるかを試す
        if let i = args.firstIndex(of: "--image-selftest"), args.count > i + 2 {
            Task { @MainActor in
                do {
                    let reading = try Camera.shared.attach(url: URL(fileURLWithPath: args[i + 1]))
                    print("読み取った文字: \(reading.text.prefix(3).joined(separator: " / "))")
                    Camera.shared.note(reading: reading.text.joined(separator: "\n"))
                    let backend = try makeBackend(.local, settings: AppSettings.shared)
                    var full = ""
                    for try await chunk in backend.respond(history: [], user: args[i + 2] + "\n（画像が添付されています。look_image ツールで見てから答えてください）", system: AgentController.shared.debugSystemPrompt()) {
                        full += chunk
                    }
                    print("答え: \(full)")
                } catch {
                    print("error: \(error)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --memory-selftest` で、記憶の保存・検索・削除を試して終了する
        if args.contains("--memory-selftest") {
            Task { @MainActor in
                let store = MemoryStore()
                print("追加1:", store.remember("山田さんは A 社の担当"))
                print("追加2（同じ）:", store.remember("山田さんは A 社の担当"))
                print("追加3（ローカル専用）:", store.remember("家族の予定は Mac の外に出さない", localOnly: true))
                print("件数:", store.items.count)
                print("検索(山田):", store.search("山田", localAllowed: false).map(\.text))
                print("クラウド時に使える件数:", store.search("", localAllowed: false).count)
                print("ローカル時に使える件数:", store.search("", localAllowed: true).count)
                print("指示文(クラウド):", store.promptSection(localAllowed: false).replacingOccurrences(of: "\n", with: " / "))
                print("消した:", store.forget(matching: "山田").map(\.text))
                print("消したあとの件数:", store.items.count)
                store.removeAll()
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --describe-selftest` で、画像対応モデルによる説明を試す（カメラは使わない）
        if args.contains("--describe-selftest") {
            Task { @MainActor in
                let image = Camera.selfTestImage()!
                let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75])!
                print("モデル: \(await VisionDescriber.model() ?? "なし")")
                let started = Date()
                print("説明: \(await VisionDescriber.describe(jpeg) ?? "（失敗）")")
                print(String(format: "%.1f秒", Date().timeIntervalSince(started)))
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --vision-selftest` で、文字と QR コードの読み取りを試して終了する（カメラは使わない）
        if args.contains("--vision-selftest") {
            do {
                let (text, codes) = try Camera.analyze(Camera.selfTestImage()!)
                print("文字:\n" + text.joined(separator: "\n"))
                print("コード: " + codes.map { "\($0.kind) \($0.value)" }.joined(separator: ", "))
            } catch {
                print("error: \(error)")
            }
            exit(0)
        }
        // 動作確認用: `AIAgent --subtitle-selftest` で、Mac の音声を英語で聞き取り、日本語字幕にできるか試す
        if args.contains("--subtitle-selftest") {
            Task { @MainActor in
                do {
                    try await Subtitles.shared.start(language: "en-US")
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-v", "Samantha", "Good morning. Could you please send me the invoice by tomorrow afternoon?"]
                    try say.run()
                    say.waitUntilExit()
                    try await Task.sleep(for: .seconds(25))
                    for line in Subtitles.shared.lines {
                        print("聞き取り: \(line.original)")
                        print("     訳: \(line.translated.isEmpty ? "（未）" : line.translated)")
                    }
                    if Subtitles.shared.lines.isEmpty { print("（何も聞き取れませんでした）") }
                    Subtitles.shared.stop()
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --translate-selftest` で、翻訳と話者の言語判定を試す
        if args.contains("--translate-selftest") {
            Task { @MainActor in
                let useAI = args.contains("--ai")
                print("訳す担当: \(useAI ? "AI" : "macOS 内蔵（無ければ AI）")")
                for (text, from, to) in [("おはようございます。今日の会議は10時からです。", "ja", "en"),
                                         ("Good morning. Could you send me the invoice today?", "en", "ja"),
                                         ("¿Podemos hablar del proyecto mañana por la tarde?", "es", "ja"),
                                         ("来週の火曜日に打ち合わせをお願いできますか。", "ja", "es")] {
                    let started = Date()
                    let result = await Interpreter.translate(text, from: from, to: to, useAI: useAI) ?? "（訳せませんでした）"
                    print(String(format: "%@→%@ [%.1f秒] %@\n   → %@", from, to, Date().timeIntervalSince(started), text, result))
                }
                print("--- 話者の判定 ---")
                for (ja, fo) in [("ハロー ハウ アー ユー", "Hello, how are you?"),
                                 ("今日の予定を教えて", "Kyo no yotei"),
                                 ("ブエノス ディアス", "Buenos días, ¿cómo estás?")] {
                    let picked = Interpreter.pick(japanese: ja, foreign: fo)
                    print("日本語側「\(ja)」/ 相手側「\(fo)」→ \(picked.map { ($0.isJapanese ? "日本語: " : "相手: ") + $0.text } ?? "なし")")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --csv-selftest <CSV>` で、CSV の読み取りを試す（連絡先には登録しない）
        if let i = args.firstIndex(of: "--csv-selftest"), args.count > i + 1 {
            let text = (try? String(contentsOf: URL(fileURLWithPath: args[i + 1]), encoding: .utf8)) ?? ""
            let people = ContactsBook.parseCSV(text)
            print("読み取れた件数: \(people.count)")
            for p in people {
                print("・姓[\(p.familyName)] 名[\(p.givenName)] 会社[\(p.organization)] 役職[\(p.jobTitle)] 電話\(p.phones) メール\(p.emails) メモ[\(p.note)]")
            }
            exit(0)
        }
        // 動作確認用: `AIAgent --image-make-selftest "頼みたい絵"` で、画像生成を試す
        if let i = args.firstIndex(of: "--image-make-selftest"), args.count > i + 1 {
            Task { @MainActor in
                let started = Date()
                do {
                    let saved = try await ImageMaker.make(prompt: args[i + 1])
                    print(String(format: "%.0f秒でできました: %@", Date().timeIntervalSince(started), saved.path))
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --contacts-selftest [探す言葉]` で、連絡先の読み取りを試す（登録はしない）
        if let i = args.firstIndex(of: "--contacts-selftest") {
            Task { @MainActor in
                print("今の許可の状態: \(CNContactStore.authorizationStatus(for: .contacts).rawValue)（0=未決定 1=制限 2=拒否 3=許可 4=一部のみ）")
                // 通常の起動（open -a）から試せるように、結果はログにも残す
                Log.write("contacts-selftest: 許可の状態 \(CNContactStore.authorizationStatus(for: .contacts).rawValue)（0=未決定 1=制限 2=拒否 3=許可 4=一部のみ）")
                do {
                    let query = args.count > i + 1 && !args[i + 1].hasPrefix("--") ? args[i + 1] : ""
                    if !query.isEmpty {
                        let found = try await ContactsBook.find(query)
                        Log.write("contacts-selftest: 『\(query)』→ \(found.replacingOccurrences(of: "\n", with: " / ").prefix(200))")
                    }
                    let birthdays = try await ContactsBook.birthdays(within: 30)
                    Log.write("contacts-selftest: 30日以内の誕生日 → \(birthdays.replacingOccurrences(of: "\n", with: " / ").prefix(200))")
                } catch {
                    Log.write("contacts-selftest: error \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --langs-selftest` で、音声認識の対応言語と端末内翻訳の可否を表示する
        if args.contains("--langs-selftest") {
            Task { @MainActor in
                let supported = await SpeechTranscriber.supportedLocales
                let installed = await SpeechTranscriber.installedLocales
                func show(_ title: String, _ locales: [Locale]) {
                    let ids = locales.map { $0.identifier(.bcp47) }.sorted()
                    print("\(title)（\(ids.count)件）: \(ids.joined(separator: ", "))")
                }
                show("音声認識に対応", supported)
                show("すでに入っている", installed)
                let availability = LanguageAvailability()
                for (from, to) in [("ja", "en"), ("en", "ja"), ("ja", "es"), ("es", "ja")] {
                    let status = await availability.status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
                    let label: String
                    switch status {
                    case .installed: label = "すぐ使える"
                    case .supported: label = "ダウンロードすれば使える"
                    case .unsupported: label = "非対応"
                    @unknown default: label = "不明"
                    }
                    print("端末内翻訳 \(from)→\(to): \(label)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --notify-selftest` で、通知の許可状態を表示し、テスト通知を出す
        if args.contains("--notify-selftest") {
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    Log.write("notify-selftest: 許可を求めた結果 \(granted)")
                } catch {
                    Log.write("notify-selftest: エラー \(error.localizedDescription)")
                }
                let settings = await center.notificationSettings()
                Log.write("notify-selftest: 状態 \(settings.authorizationStatus.rawValue)（0=未決定 1=拒否 2=許可 3=暫定）")
                Notifier.show(title: "AIエージェント", body: "通知のテストです")
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --tools-selftest` で、組み込みの機能が動くかを1つずつ試して表示し、終了する
        if args.contains("--tools-selftest") {
            Task { @MainActor in
                for line in await Tools.selfTestReport() { print(line) }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --meeting-selftest` で、別アプリの音声（say）が「相手」として文字起こしされるかを表示して終了する
        if args.contains("--meeting-selftest") {
            Task { @MainActor in
                let rec = MeetingRecorder()
                do {
                    try await rec.start()
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-v", "Kyoko", "本日の議題は新製品の発売日です。発売は十月一日に決定しました。山田さんは来週金曜までに見積もりを出してください。"]
                    try say.run()
                    say.waitUntilExit()
                    try await Task.sleep(for: .seconds(4))
                    let text = await rec.stop()
                    print("transcript:\n\(text)\nfile: \(rec.fileURL?.path ?? "-")")
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --oauth-selftest <名前>` でログインを実行し、接続状況を表示して終了する
        if let j = args.firstIndex(of: "--oauth-selftest"), args.count > j + 1 {
            Task { @MainActor in
                let mcp = MCPManager.shared
                await mcp.reload()
                do { try await mcp.login(args[j + 1]); print("login ok") } catch { print("login error: \(error.localizedDescription)") }
                print("loggedIn: \(OAuthManager.shared.loggedIn)")
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --discover-selftest <URL>...` でログイン方式の自動検出だけを試す（アプリ登録はしない）
        if let k = args.firstIndex(of: "--discover-selftest") {
            Task { @MainActor in
                for u in args[(k + 1)...] {
                    do {
                        let oc = try await OAuthDiscovery.discover(serverURL: URL(string: u)!, redirectURI: "http://127.0.0.1:8723/oauth2callback", clientId: "dummy")
                        print("\(u)\n  authorize=\(oc.authorizeURL)\n  token=\(oc.tokenURL)\n  scopes=\(oc.scopes)")
                    } catch {
                        print("\(u)\n  error: \(error.localizedDescription)")
                    }
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --llm-selftest "質問"` でローカル AI に1回質問し、ツールの呼び出しと答えを表示する
        if let q = args.firstIndex(of: "--llm-selftest"), args.count > q + 1 {
            Task { @MainActor in
                await MCPManager.shared.reload()
                print("tools: \(Tools.specs(local: true).count)")
                let backend = try! makeBackend(.local, settings: AppSettings.shared)
                var out = ""
                // アプリ本体と同じように、資料から関係しそうな箇所を先に添える
                var question = args[q + 1]
                if !Library.shared.sources.isEmpty {
                    let found = Library.shared.context(for: question, limit: 4)
                    if !found.isEmpty {
                        print("資料から \(found.components(separatedBy: "【").count - 1)か所を添えました")
                        question += "\n\n（登録された資料から、関係しそうな箇所です。答えに使ったときは【】の資料名を一言添えてください。ここに無いことは「資料には書かれていません」と答えてください）\n" + found
                    }
                }
                do {
                    for try await c in backend.respond(history: [], user: question, system: AgentController.shared.debugSystemPrompt()) { out += c }
                } catch { out = "error: \(error)" }
                print("answer: \(out)")
                exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "--mcp-selftest") else { return }
        Task { @MainActor in
            let mcp = MCPManager.shared
            await mcp.reload()
            for name in mcp.serverNames {
                print("[\(name)] \(mcp.status[name]?.label ?? "-") \(mcp.toolNames(of: name))")
            }
            if args.count > i + 2 {
                let (out, isError) = await Tools.execute(name: args[i + 1], arguments: args[i + 2])
                print("call \(args[i + 1]) → error=\(isError)\n\(out)")
            }
            print("specs: local=\(Tools.specs(local: true).count) cloud=\(Tools.specs(local: false).count)")
            if args.count > i + 2, mcp.handles(args[i + 1]) {
                let (out, isError) = await mcp.call(args[i + 1], arguments: args[i + 2], localAllowed: false)
                print("cloud call → error=\(isError) \(out.prefix(80))")
            }
            exit(0)
        }
    }

    /// メニューバーのみ: Dock に出さない / ウィンドウ＋Dock: 通常のアプリとして振る舞う
    @MainActor static func applyDisplayMode(_ mode: DisplayMode) {
        NSApp.setActivationPolicy(mode == .window ? .regular : .accessory)
        if mode == .window { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MCPManager.shared.terminateProcesses() }
    }

    // 常駐アプリなのでウィンドウを閉じても終了しない
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Dock アイコンのクリックでメインウィンドウを開き直す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                if AppSettings.shared.isNamed { Self.openWindow?("main") } else { Self.openWindow?("onboarding") }
            }
        }
        return true
    }
}
