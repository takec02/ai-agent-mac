import AppKit
import AVFoundation
import Vision

/// 頼まれたときだけカメラで1枚撮り、Mac の中で文字とコード（QR・バーコード）を読み取る。
/// 撮った写真は画面に小さく出し、何を見たのかが分かるようにする。常時の撮影はしない（在席の確認は別）
@MainActor
@Observable
final class Camera {
    static let shared = Camera()

    /// 直前に撮った写真（画面の確認用）
    private(set) var lastPhoto: NSImage?
    private(set) var lastPhotoAt: Date?
    /// 画面に出すときの見出し（「カメラで見たもの」「作った画像」）
    private(set) var lastPhotoLabel = "カメラで見たもの"
    /// 直前に読み取った内容（「これ、予定に入れて」のように後から指されたときに使う）
    private(set) var lastReading: String?

    /// 撮った写真を AI に渡すための JPEG。道具の結果と一緒にバックエンドが取り出して送る
    private var pendingJPEG: Data?

    struct Reading {
        let jpeg: Data
        let text: [String]
        let codes: [(kind: String, value: String)]
    }

    /// 撮るときに鳴らすシャッター音（Mac に入っているもの）
    private static let shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif", byReference: true)

    /// 1枚撮って、文字とコードを読み取る
    func look() async throws -> Reading {
        lastPhotoLabel = "カメラで見たもの"
        let image = try await Self.capture()
        Self.shutter?.play()  // 撮ったことが分かるように鳴らす
        let (text, codes) = try await Task.detached(priority: .userInitiated) { try Self.analyze(image) }.value
        guard let jpeg = Self.jpeg(image, maxSide: 1024) else { throw Tools.ToolError(message: "写真を画像にできませんでした") }
        lastPhoto = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        lastPhotoAt = Date()
        pendingJPEG = jpeg
        return Reading(jpeg: jpeg, text: text, codes: codes)
    }

    /// 撮ったばかりの写真を1回だけ取り出す（2回送らない）
    func takePendingJPEG() -> Data? {
        defer { pendingJPEG = nil }
        return pendingJPEG
    }

    func clearPhoto() {
        lastPhoto = nil
        lastPhotoAt = nil
        lastReading = nil
        pendingJPEG = nil
        hasAttachment = false
    }

    /// ユーザーから渡された画像が、まだ AI に見せられていないか
    private(set) var hasAttachment = false

    /// ファイルやドラッグで渡された画像を取り込む（カメラと同じ扱いにする）
    @discardableResult
    func attach(url: URL) throws -> Reading {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Tools.ToolError(message: "画像として読めませんでした: \(url.lastPathComponent)")
        }
        return try attach(image: image)
    }

    @discardableResult
    func attach(image: CGImage) throws -> Reading {
        lastPhotoLabel = "渡された画像"
        let (text, codes) = try Self.analyze(image)
        guard let jpeg = Self.jpeg(image, maxSide: 1024) else { throw Tools.ToolError(message: "画像を変換できませんでした") }
        lastPhoto = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        lastPhotoAt = Date()
        pendingJPEG = jpeg
        hasAttachment = true
        return Reading(jpeg: jpeg, text: text, codes: codes)
    }

    func attachmentUsed() { hasAttachment = false }

    /// 作った画像などを、カメラの写真と同じ場所に出す
    func show(image: NSImage, label: String) {
        lastPhoto = image
        lastPhotoAt = Date()
        lastPhotoLabel = label
        lastReading = nil
        hasAttachment = false
    }

    /// 読み取った内容を覚えておく（10分以内なら「これ」で参照できる）
    func note(reading: String) { lastReading = reading }

    /// 直前に見たものを、話の流れに足すべきか
    func recentReading(for text: String) -> String? {
        guard let reading = lastReading, let at = lastPhotoAt, Date().timeIntervalSince(at) < 600 else { return nil }
        let words = ["これ", "この", "それ", "さっきの写真", "さっき見た", "写真"]
        return words.contains(where: text.contains) ? reading : nil
    }

    // MARK: 撮影

    private static func capture() async throws -> CGImage {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw denied() }
        default: throw denied()
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw Tools.ToolError(message: "カメラが見つかりません")
        }
        let grabber = FrameGrabber()
        return try await grabber.grab(from: device)
    }

    private static func denied() -> Tools.ToolError {
        Tools.ToolError(message: "カメラの使用が許可されていません（システム設定 → プライバシーとセキュリティ → カメラ）")
    }

    // MARK: 読み取り（Mac の中で行う）

    nonisolated static func analyze(_ image: CGImage) throws -> ([String], [(kind: String, value: String)]) {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["ja-JP", "en-US"]
        textRequest.usesLanguageCorrection = true
        let codeRequest = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([textRequest, codeRequest])

        // 上から下、左から右の順に並べる（Vision の座標は左下が原点）
        let lines = (textRequest.results ?? [])
            .sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        var seen = Set<String>()
        let codes = (codeRequest.results ?? []).compactMap { r -> (kind: String, value: String)? in
            guard let v = r.payloadStringValue, seen.insert(v).inserted else { return nil }
            return (r.symbology == .qr ? "QR コード" : "バーコード（\(r.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: ""))）", v)
        }
        return (lines, codes)
    }

    nonisolated private static func jpeg(_ image: CGImage, maxSide: CGFloat) -> Data? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

/// カメラを短時間だけ動かし、明るさが落ち着いたころの1コマを取り出す
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.frames")
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var startedAt = Date.distantFuture
    private let context = CIContext()

    func grab(from device: AVCaptureDevice) async throws -> CGImage {
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw Tools.ToolError(message: "カメラを使えません（別のアプリが使用中の可能性があります）") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Tools.ToolError(message: "カメラを使えません") }
        session.addOutput(output)
        session.commitConfiguration()

        defer { session.stopRunning() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    self.continuation = cont
                    self.startedAt = Date()
                    self.session.startRunning()
                    // 映像が来ないまま終わらないよう、8秒で打ち切る
                    self.queue.asyncAfter(deadline: .now() + 8) {
                        self.finish(.failure(Tools.ToolError(message: "カメラから映像が届きませんでした")))
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 起動直後は暗かったりピントが合っていなかったりするので、少し待ってから使う
        guard continuation != nil, Date().timeIntervalSince(startedAt) > 1.0,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent) else { return }
        finish(.success(image))
    }

    /// queue の上で呼ぶ
    private func finish(_ result: Result<CGImage, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }
}

// MARK: 動作確認用

extension Camera {
    /// 文字と QR コードを描いた画像を作り、読み取れるかを確かめる（カメラは使わない）
    nonisolated static func selfTestImage() -> CGImage? {
        let w = 1200, h = 700
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        for (i, line) in ["株式会社サンプル商事", "営業部 山田 太郎", "TEL 03-1234-5678", "yamada@example.co.jp"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: h - 110 - i * 80), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/menu".utf8)])!
            .outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        if let q = CIContext().createCGImage(qr, from: qr.extent) {
            ctx.draw(q, in: CGRect(x: w - 60 - q.width, y: 60, width: q.width, height: q.height))
        }
        return ctx.makeImage()
    }
}
