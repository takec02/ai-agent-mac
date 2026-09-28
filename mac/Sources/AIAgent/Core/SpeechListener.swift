import AVFoundation
import Speech

/// マイクの音声を macOS 内蔵の音声認識 (SpeechAnalyzer) に流し続け、認識結果を通知する。
final class SpeechListener: @unchecked Sendable {
    /// 認識結果。locale は、どの言語の認識器が出したか（通訳では話者の言語の判定に使う）
    typealias Handler = @MainActor (_ text: String, _ isFinal: Bool, _ locale: Locale) -> Void

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var _muted = false
    /// true の間はマイク音声を捨てる（自分の読み上げを聞き取らないため）
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// マイクの音量 (0〜1) を約20回/秒で通知する。ミュート中は 0
    var onLevel: (@Sendable (Double) -> Void)?
    private var lastLevelTime: TimeInterval = 0

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 複数の言語を同時に聞き取れる（通訳のときは日本語と相手の言語の2つ）
    func start(locales: [Locale], contextWords: [String], onStatus: @escaping @MainActor (String) -> Void, onResult: @escaping Handler) async throws {
        // 途中経過は受け取りつつ、速さ優先 (fastResults) にはしない。確定結果の精度を優先するため
        let transcribers = locales.map {
            SpeechTranscriber(locale: $0, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
            await onStatus("音声認識モデルをダウンロード中…")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: transcribers)
        self.analyzer = analyzer
        await setContext(contextWords)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) else {
            throw NSError(domain: "AIAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "音声認識の形式を取得できません"])
        }
        targetFormat = format
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        resultsTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for (transcriber, locale) in zip(transcribers, locales) {
                    group.addTask {
                        do {
                            for try await result in transcriber.results {
                                await onResult(String(result.text.characters), result.isFinal, locale)
                            }
                        } catch {
                            await onStatus("音声認識が停止しました: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        try await analyzer.start(inputSequence: stream)
        try startEngine()

        // マイクの抜き差しや出力先の変更でエンジンが止まったら張り直す
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            try? self?.startEngine()
        }
    }

    func setContext(_ words: [String]) async {
        guard let analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try? await analyzer.setContext(context)
    }

    /// マイクがつながっているか（Mac Studio のように、マイクの無い Mac もある）
    static var hasMicrophone: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    private func startEngine() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        // マイクが無いと形式が 0Hz になり、取り付けたところで例外で落ちる
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AIAgent", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "マイクが見つかりません。マイクをつなぐか、キーボードのボタンから文字で話しかけてください",
            ])
        }
        guard let targetFormat else { return }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer, muted: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelTime > 0.05, let onLevel else { return }
        lastLevelTime = now
        guard !muted, let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            onLevel(0)
            return
        }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // 話し声がおおよそ 0〜1 に収まるよう対数スケールに変換
        let db = 20 * log10(max(rms, 1e-6))
        onLevel(Double(max(0, min(1, (db + 55) / 40))))
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let muted = self.muted
        reportLevel(buffer, muted: muted)
        guard !muted, let converter, let targetFormat, let continuation else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }

    func stop() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }
}
