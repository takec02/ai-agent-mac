import AppKit
import Foundation

/// ローカル AI（Ollama）が止まっていたら起動する。
/// Ollama はアプリ版（/Applications/Ollama.app）と、Homebrew などで入れたコマンド版がある
@MainActor
@Observable
final class OllamaLauncher {
    static let shared = OllamaLauncher()

    /// 動いているか（画面のボタンを出すかどうかに使う）
    private(set) var running = true
    private(set) var starting = false

    private let host = "http://localhost:11434"

    /// 動いているかを確かめる
    @discardableResult
    func check() async -> Bool {
        var request = URLRequest(url: URL(string: "\(host)/api/tags")!)
        request.timeoutInterval = 2
        let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
        running = ok
        return ok
    }

    /// 起動して、使えるようになるまで待つ（最大20秒）。起動できたら true
    @discardableResult
    func start() async -> Bool {
        if await check() { return true }
        guard !starting else { return false }
        starting = true
        defer { starting = false }
        Log.write("ollama: starting")

        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            // アプリ版は、アプリを開けば裏で待ち受けが始まる
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                                                              configuration: config)
        } else if let path = Self.commandPath() {
            // コマンド版は、待ち受けを裏で動かす（このアプリを閉じても残る）
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "nohup '\(path)' serve > /tmp/ollama-serve.log 2>&1 &"]
            try? process.run()
            process.waitUntilExit()
        } else {
            Log.write("ollama: not installed")
            return false
        }

        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if await check() {
                Log.write("ollama: started")
                return true
            }
        }
        Log.write("ollama: did not start in time")
        return false
    }

    /// Homebrew などで入れた ollama コマンドの場所
    static func commandPath() -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "\(NSHomeDirectory())/.local/bin/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 入っているか（どちらの形でもなければ、ダウンロードを案内する）
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app") || commandPath() != nil
    }
}
