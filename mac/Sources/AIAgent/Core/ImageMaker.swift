import AppKit
import ImagePlayground

/// 頼まれた絵を、この Mac の中（Apple の Image Playground）で作る。
/// 癖: アプリが前に出ていないと作れない。知らない単語が入ると断られる。日本語より英語の簡単な単語のほうが思いどおりになる
@MainActor
enum ImageMaker {
    /// 保存先（作った絵は、あとから見返せるように残す）
    static let folder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AIエージェント/画像")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 画風（外部のサービスに送る画風は使わない）
    static let styles: [String: ImagePlaygroundStyle] = [
        "illustration": .illustration, "animation": .animation, "sketch": .sketch,
    ]

    /// 絵を作り、保存したファイルの場所を返す
    @discardableResult
    static func make(prompt: String, style: String = "illustration") async throws -> URL {
        // 前に出ていないと作れないので、画面を前に出してから頼む
        NSApp.activate()
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            throw friendly(error)
        }
        let chosen = styles[style] ?? .illustration
        var image: CGImage?
        do {
            for try await created in creator.images(for: [.text(prompt)], style: chosen, limit: 1) {
                image = created.cgImage
            }
        } catch {
            throw friendly(error)
        }
        guard let image else { throw Tools.ToolError(message: "絵を作れませんでした") }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Tools.ToolError(message: "作った絵を保存できませんでした")
        }
        let saved = folder.appendingPathComponent(fileName(for: prompt))
        try data.write(to: saved)
        Camera.shared.show(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                           label: "作った画像")
        Log.write("image generated: \(saved.lastPathComponent)")
        return saved
    }

    /// Image Playground の失敗を、ユーザーと AI に分かる言葉にする
    private static func friendly(_ error: Error) -> Tools.ToolError {
        guard let e = error as? ImageCreator.Error else {
            return Tools.ToolError(message: "絵を作れませんでした（\(error.localizedDescription)）")
        }
        Log.write("image error: \(e)")
        switch e {
        case .notSupported, .unavailable:
            return Tools.ToolError(message: "この Mac では絵を作れません（Apple Intelligence を有効にする必要があります）")
        case .backgroundCreationForbidden:
            return Tools.ToolError(message: "アプリの画面が前に出ていないため、絵を作れませんでした。画面を前に出して、もう一度頼んでください")
        case .unsupportedLanguage:
            return Tools.ToolError(message: "絵にできない言葉が入っていました。prompt をもっと簡単な英単語にして、もう一度 generate_image を呼んでください")
        case .conceptsRequirePersonIdentity:
            return Tools.ToolError(message: "実在の人物の絵は作れません")
        default:
            return Tools.ToolError(message: "絵を作れませんでした（\(e)）")
        }
    }

    /// 「a cat」→「2026-11-02_1530_a cat.png」
    private static func fileName(for prompt: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let words = prompt.prefix(30).replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stamp.string(from: Date()))_\(words).png"
    }
}
