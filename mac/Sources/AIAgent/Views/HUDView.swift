import SwiftUI

// MARK: - 状態ごとの色と勢い

extension AgentState {
    var tint: Color {
        switch self {
        case .idle, .starting, .needsName: Color(red: 0.30, green: 0.78, blue: 1.00)
        case .listening: Color(red: 0.35, green: 0.95, blue: 1.00)
        case .thinking: Color(red: 0.68, green: 0.50, blue: 1.00)
        case .speaking: Color(red: 0.35, green: 1.00, blue: 0.80)
        case .paused: Color(red: 1.00, green: 0.66, blue: 0.30)
        case .error: Color(red: 1.00, green: 0.36, blue: 0.42)
        }
    }

    /// 回転の速さや揺れの大きさ (0〜1)
    var energy: Double {
        switch self {
        case .idle: 0.12
        case .listening: 0.55
        case .thinking: 1.0
        case .speaking: 0.75
        case .paused: 0.03
        case .error: 0.25
        case .starting, .needsName: 0.35
        }
    }
}

// MARK: - 幾何学コア

/// 回転するリング・多角形・波形で状態を表すコア
struct CoreView: View {
    var state: AgentState
    var level: Double = 0  // マイク音量 0〜1

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(&ctx, size: size, t: t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 * 0.94
        let tint = state.tint
        let e = state.energy
        let speed = 0.25 + e * 1.6
        let dim = state == .paused ? 0.45 : 1.0
        ctx.addFilter(.shadow(color: tint.opacity(0.9 * dim), radius: 6))

        func point(_ r: Double, _ a: Double) -> CGPoint {
            CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        func polygon(sides: Int, radius: Double, rotation: Double) -> Path {
            Path { p in
                for i in 0...sides {
                    let pt = point(radius, rotation + Double(i) / Double(sides) * 2 * .pi)
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
        }

        // 1) 外周の目盛り
        let tickRot = t * 0.06 * speed
        var ticks = Path()
        for i in 0..<90 {
            let a = tickRot + Double(i) / 90 * 2 * .pi
            let major = i % 15 == 0
            ticks.move(to: point(R * (major ? 0.88 : 0.93), a))
            ticks.addLine(to: point(R, a))
        }
        ctx.stroke(ticks, with: .color(tint.opacity(0.45 * dim)), lineWidth: 1)

        // 2) 途切れた円弧（逆回転）
        let arcRot = -t * 0.35 * speed
        for k in 0..<3 {
            let start = arcRot + Double(k) * 2 * .pi / 3
            let arc = Path { p in
                p.addArc(center: c, radius: R * 0.8, startAngle: .radians(start), endAngle: .radians(start + 1.5), clockwise: false)
            }
            ctx.stroke(arc, with: .color(tint.opacity(0.85 * dim)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        // 細い全周リング
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R * 0.72, y: c.y - R * 0.72, width: R * 1.44, height: R * 1.44)),
                   with: .color(tint.opacity(0.18 * dim)), lineWidth: 0.8)

        // 3) 回転する六角形と逆回転の三角形
        ctx.stroke(polygon(sides: 6, radius: R * 0.62, rotation: t * 0.18 * speed),
                   with: .color(tint.opacity(0.7 * dim)), lineWidth: 1.2)
        ctx.stroke(polygon(sides: 3, radius: R * 0.62, rotation: -t * 0.26 * speed + .pi / 2),
                   with: .color(tint.opacity(0.35 * dim)), lineWidth: 1)

        // 4) 考え中: 周回する点
        if state == .thinking {
            for i in 0..<6 {
                let a = t * 2.4 + Double(i) * .pi / 3
                let pt = point(R * 0.72, a)
                let r = 2.6 - Double(i) * 0.25
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(tint))
            }
        }

        // 5) 反応する波形リング（聞いている間は声の大きさ、話している間は波打つ）
        let amp: Double = switch state {
        case .listening: 0.03 + level * 0.28
        case .speaking: 0.06 + 0.08 * abs(sin(t * 7))
        case .thinking: 0.05
        default: 0.015 + level * 0.1
        }
        let wave = Path { p in
            let n = 160
            for i in 0...n {
                let a = Double(i) / Double(n) * 2 * .pi
                let noise = sin(a * 6 + t * 3.1) * 0.5 + sin(a * 11 - t * 4.7) * 0.3 + sin(a * 17 + t * 6.3) * 0.2
                let pt = point(R * 0.42 * (1 + amp * noise), a)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }
        ctx.stroke(wave, with: .color(tint.opacity(0.95 * dim)), lineWidth: 1.6)

        // 6) 中心の光
        let breathe = 1 + 0.06 * sin(t * 2.2) + level * 0.5
        let coreR = R * 0.16 * breathe
        let glow = Path(ellipseIn: CGRect(x: c.x - coreR * 2, y: c.y - coreR * 2, width: coreR * 4, height: coreR * 4))
        ctx.fill(glow, with: .radialGradient(Gradient(colors: [tint.opacity(0.55 * dim), .clear]),
                                             center: c, startRadius: 0, endRadius: coreR * 2))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - coreR * 0.45, y: c.y - coreR * 0.45, width: coreR * 0.9, height: coreR * 0.9)),
                 with: .color(.white.opacity(0.9 * dim)))
    }
}

// MARK: - 流れるメッセージ

/// 新しい発言ほど上に大きく、古い発言は下へ押し出されながら横へ流れて消えていく。
/// あなたの発言は左へ、AI の発言は右へ流れる。
struct FlowingLog: View {
    let entries: [ConversationEntry]
    let name: String
    let tint: Color
    var maxItems = 6
    var drift: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let items = Array(entries.suffix(maxItems).reversed().enumerated())
            ZStack(alignment: .top) {
                ForEach(items, id: \.element.id) { age, entry in
                    LogLine(entry: entry, name: name, tint: tint, newest: age == 0)
                        .frame(width: geo.size.width * 0.84)
                        .scaleEffect(1 - CGFloat(age) * 0.06, anchor: .top)
                        .offset(x: direction(entry) * CGFloat(age) * drift, y: yOffset(age))
                        .opacity(max(0, 1 - Double(age) * 0.19))
                        .blur(radius: age >= 3 ? CGFloat(age - 2) * 0.7 : 0)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -14)),
                            removal: .opacity.combined(with: .offset(x: direction(entry) * drift * 2))
                        ))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(.spring(response: 0.7, dampingFraction: 0.85), value: entries.map(\.id))
        }
        .clipped()
    }

    private func direction(_ e: ConversationEntry) -> CGFloat {
        switch e.role {
        case "user": -1
        case "assistant": 1
        default: 0
        }
    }

    private func yOffset(_ age: Int) -> CGFloat {
        age == 0 ? 0 : 70 + CGFloat(age - 1) * 26
    }
}

private struct LogLine: View {
    let entry: ConversationEntry
    let name: String
    let tint: Color
    let newest: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(entry.role == "user" ? Color.white.opacity(0.45) : tint.opacity(0.85))
            Text(entry.text.isEmpty ? "···" : entry.text)
                .font(.system(size: newest ? 15 : 12, weight: newest ? .regular : .light))
                .foregroundStyle(.white.opacity(entry.role == "system" ? 0.55 : 0.92))
                .multilineTextAlignment(.center)
                .lineLimit(newest ? 3 : 1)
                .textSelection(.enabled)
        }
    }

    private var tag: String {
        switch entry.role {
        case "user": "◂ YOU"
        case "assistant": "\(name.uppercased()) ▸"
        default: "· SYSTEM ·"
        }
    }
}

// MARK: - 背景

struct HUDBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.05)
            Canvas { ctx, size in
                var grid = Path()
                let step: CGFloat = 22
                stride(from: 0, through: size.width, by: step).forEach { x in
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: 0, through: size.height, by: step).forEach { y in
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
            }
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.32), startRadius: 0, endRadius: 320)
                .animation(.easeInOut(duration: 0.6), value: tint)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 画面全体

/// メインウィンドウとメニューバーのパネルで共通の HUD 画面
struct HUDView: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// カーソルを合わせているボタンの説明（すぐ出す）
    @State private var hoveredLabel: String?
    @State private var showInput = false
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    var compact = false

    var body: some View {
        let s = agent.settings
        let tint = agent.state.tint
        ZStack {
            HUDBackground(tint: tint)
            VStack(spacing: 0) {
                header(tint: tint)
                liveLine(tint: tint)
                    .frame(height: 22)
                    .padding(.horizontal, 20)
                CoreView(state: agent.state, level: agent.level)
                    .frame(width: compact ? 170 : 250, height: compact ? 170 : 250)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottomTrailing) { cameraPhoto(tint: tint).padding(.trailing, 16) }
                    .padding(.vertical, compact ? 4 : 10)
                FlowingLog(entries: agent.entries, name: s.agentName, tint: tint, maxItems: compact ? 5 : 7)
                    .frame(maxHeight: .infinity)
                if let q = agent.pendingConfirmation { confirmBar(q, tint: tint) }
                if showInput { inputField(tint: tint) }
                controls(tint: tint)
            }
        }
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in agent.attachImage(url) }
            }
            return true
        }
    }

    private func header(tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.settings.agentName.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(.white.opacity(0.9))
                Text(agent.state.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(2)
            }
            Spacer()
            if agent.meeting.isRecording, let start = agent.meeting.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let sec = Int(ctx.date.timeIntervalSince(start))
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(String(format: "REC %d:%02d", sec / 60, sec % 60))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.trailing, 6)
            }
            Text(agent.settings.backend.shortLabel.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(tint.opacity(0.9))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.8))
        }
        .padding(.horizontal, 18)
        .padding(.top, compact ? 14 : 30)
    }

    @ViewBuilder
    private func liveLine(tint: Color) -> some View {
        if !agent.liveText.isEmpty {
            Text("▸ \(agent.liveText)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.head)
        } else if let until = agent.conversationUntil, agent.state == .listening {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(until.timeIntervalSince(ctx.date)))
                Text("会話中 ─ 名前を呼ばずに話しかけられます（あと \(left / 60):\(String(format: "%02d", left % 60))）")
                    .font(.system(size: 11))
                    .foregroundStyle(tint.opacity(0.8))
            }
        } else if agent.state == .idle {
            Text("「\(agent.settings.wakeExample)」と呼びかけてください")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    /// 画像ファイルを選んで渡す
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "渡す"
        panel.message = "見てもらう画像を選んでください"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { agent.attachImage(url) }
    }

    /// カメラで撮った写真（AI が何を見たのかを確かめられるように出しておく）
    @ViewBuilder
    private func cameraPhoto(tint: Color) -> some View {
        if let photo = Camera.shared.lastPhoto {
            VStack(alignment: .trailing, spacing: 3) {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: compact ? 84 : 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.6), lineWidth: 0.8))
                    .overlay(alignment: .topTrailing) {
                        Button { Camera.shared.clearPhoto() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.85), .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("写真を消す")
                        .padding(3)
                    }
                Text("カメラで見たもの \(Camera.shared.lastPhotoAt?.formatted(date: .omitted, time: .standard) ?? "")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
    }

    /// 書き込み前の確認（声でも答えられる）
    private func confirmBar(_ question: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Text(question)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("やめる") { agent.resolveConfirmation(false) }
                    .buttonStyle(.bordered)
                Button("実行する") { agent.resolveConfirmation(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            }
            Text("「はい」「いいえ」と声でも答えられます")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 0.8))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func inputField(tint: Color) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $input, prompt: Text("文字で話しかける").foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up") }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.45), lineWidth: 0.8))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .onAppear { inputFocused = true }
    }

    private func controls(tint: Color) -> some View {
        VStack(spacing: 4) {
            // カーソルを合わせたボタンが何なのかを、すぐ分かるように出す
            Text(hoveredLabel ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(tint.opacity(hoveredLabel == nil ? 0 : 0.9))
                .animation(.easeOut(duration: 0.12), value: hoveredLabel)
            controlRow(tint: tint)
        }
    }

    @ViewBuilder
    private func controlRow(tint: Color) -> some View {
        @Bindable var s = agent.settings
        HStack(spacing: 14) {
            HUDButton(symbol: agent.isPaused ? "mic.slash" : "mic", tint: tint, help: agent.isPaused ? "マイクを再開" : "マイクを一時停止", onHover: { hoveredLabel = $0 }) {
                agent.toggleMicrophone()
            }
            HUDButton(symbol: "keyboard", tint: tint, help: "文字で話しかける", active: showInput, onHover: { hoveredLabel = $0 }) {
                withAnimation(.easeOut(duration: 0.2)) { showInput.toggle() }
            }
            Menu {
                Picker("AI", selection: $s.backend) {
                    ForEach(BackendKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 13))
                    .foregroundStyle(tint.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 0.8))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("AI を切り替え")
            .onHover { inside in hoveredLabel = inside ? "AI を切り替え（今は\(s.backend.label)）" : nil }
            HUDButton(symbol: agent.meeting.isRecording ? "stop.circle.fill" : "record.circle", tint: agent.meeting.isRecording ? .red : tint,
                      help: agent.meeting.isRecording ? "会議の記録を終了して要約" : "会議を記録", active: agent.meeting.isRecording, onHover: { hoveredLabel = $0 }) {
                agent.toggleMeeting()
            }
            HUDButton(symbol: "books.vertical", tint: tint, help: "資料を登録する（その内容について聞けます）", onHover: { hoveredLabel = $0 }) {
                NSApp.activate()
                openWindow(id: "library")
            }
            HUDButton(symbol: "doc.text", tint: tint, help: "議事録を読む", onHover: { hoveredLabel = $0 }) {
                NSApp.activate()
                openWindow(id: "notes")
            }
            HUDButton(symbol: "captions.bubble", tint: tint,
                      help: Subtitles.shared.running ? "字幕をやめる" : "会議・動画に日本語字幕を出す",
                      active: Subtitles.shared.running, onHover: { hoveredLabel = $0 }) {
                agent.toggleSubtitles()
            }
            HUDButton(symbol: "globe", tint: tint,
                      help: agent.interpreting ? "通訳をやめる" : "通訳する（日本語 ⇄ \(Interpreter.label(for: agent.settings.interpreterLanguage))）",
                      active: agent.interpreting) {
                agent.toggleInterpreting()
            }
            HUDButton(symbol: "photo", tint: tint, help: "画像を渡して見てもらう") { pickImage() }
            HUDButton(symbol: "trash", tint: tint, help: "会話を消去して、呼びかけ待ちに戻る") { agent.clearConversation() }
            HUDButton(symbol: "gearshape", tint: tint, help: "設定", onHover: { hoveredLabel = $0 }) {
                NSApp.activate()
                openSettings()
            }
            if compact {
                HUDButton(symbol: "power", tint: tint, help: "終了") { NSApp.terminate(nil) }
            }
        }
        .padding(.vertical, 12)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        agent.handle(text)
    }
}

private struct HUDButton: View {
    let symbol: String
    let tint: Color
    let help: String
    var active = false
    var onHover: ((String?) -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? Color.black : tint.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? tint : .clear))
                .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in onHover?(inside ? help : nil) }
    }
}
