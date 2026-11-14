import AppKit
import Foundation

/// 提案書を PDF・PowerPoint（.pptx）のファイルにする。どちらも 16:9 で、同じ見た目にそろえる
enum ProposalRenderer {
    /// 見出しや線の色（落ち着いた紺）
    static let accent = (r: 0.11, g: 0.23, b: 0.42)
    static let accentHex = "1C3A6B"
    static let font = "Hiragino Sans"

    // MARK: PDF

    static func pdf(_ deck: ProposalDeck, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw Tools.ToolError(message: "PDF を作れませんでした")
        }
        let accentColor = NSColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1)
        func page(_ draw: () -> Void) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        /// 上からの位置で文字を置く（PDF は左下が原点なので変換する）
        /// bottom を渡すと、文の下端をそこにそろえる（表紙の題名を線の上に置くため）
        func text(_ s: String, size: CGFloat, bold: Bool = false, color: NSColor = .black, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, bottom: CGFloat? = nil) {
            let f = NSFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = size * 0.35
            style.paragraphSpacing = size * 0.6
            let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: style])
            var y = 540 - top - height
            var h = height
            if let bottom {
                h = min(height, ceil(str.boundingRect(with: CGSize(width: width, height: height), options: .usesLineFragmentOrigin).height))
                y = 540 - bottom
            }
            str.draw(with: CGRect(x: x, y: y, width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        // 表紙
        page {
            accentColor.setFill()
            CGRect(x: 0, y: 0, width: 960, height: 540).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            CGRect(x: 72, y: 540 - 300, width: 80, height: 4).fill()
            text(deck.title, size: 38, bold: true, color: .white, x: 72, top: 120, width: 816, height: 160, bottom: 284)
            text(deck.subtitle, size: 18, color: NSColor.white.withAlphaComponent(0.85), x: 72, top: 320, width: 816, height: 60)
        }
        // 中身
        for (i, slide) in deck.slides.enumerated() {
            page {
                NSColor.white.setFill()
                CGRect(x: 0, y: 0, width: 960, height: 540).fill()
                accentColor.setFill()
                CGRect(x: 0, y: 540 - 8, width: 960, height: 8).fill()
                text(slide.heading, size: 28, bold: true, color: accentColor, x: 64, top: 48, width: 832, height: 50)
                accentColor.withAlphaComponent(0.25).setFill()
                CGRect(x: 64, y: 540 - 108, width: 832, height: 1.5).fill()
                let body = slide.bullets.map { "・\($0)" }.joined(separator: "\n")
                text(body, size: 20, color: NSColor(white: 0.15, alpha: 1), x: 72, top: 132, width: 816, height: 360)
                text("\(i + 2)", size: 11, color: .gray, x: 880, top: 506, width: 40, height: 20)
            }
        }
        ctx.closePDF()
    }

    // MARK: PowerPoint

    /// 1インチ = 914400。16:9 の大きさ（13.333 × 7.5 インチ）
    private static let width = 12_192_000, height = 6_858_000

    static func pptx(_ deck: ProposalDeck, to url: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        var files: [String: String] = [:]
        let count = deck.slides.count + 1

        files["[Content_Types].xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \((1...count).map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined(separator: "\n"))
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
        files["_rels/.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
        files["docProps/core.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(esc(deck.title))</dc:title><dc:creator>AIエージェント</dc:creator>
        </cp:coreProperties>
        """
        files["docProps/app.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>AIエージェント</Application><Slides>\(count)</Slides></Properties>
        """
        files["ppt/presentation.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\((1...count).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined())</p:sldIdLst>
        <p:sldSz cx="\(width)" cy="\(height)"/><p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
        files["ppt/_rels/presentation.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        \((1...count).map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>" }.joined(separator: "\n"))
        <Relationship Id="rId\(count + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        </Relationships>
        """
        files["ppt/slideMasters/slideMaster1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
        files["ppt/slideLayouts/slideLayout1.xml"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
        <p:cSld name="白紙"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
        files["ppt/theme/theme1.xml"] = theme

        // 表紙
        files["ppt/slides/slide1.xml"] = slideXML([
            rect(id: 2, x: 0, y: 0, cx: width, cy: height, color: accentHex),
            rect(id: 3, x: 914_400, y: 3_840_000, cx: 1_016_000, cy: 50_800, color: "FFFFFF"),
            textBox(id: 4, x: 914_400, y: 2_160_000, cx: 10_363_200, cy: 1_524_000,
                    paragraphs: [deck.title], size: 4000, bold: true, color: "FFFFFF", anchor: "b"),
            textBox(id: 5, x: 914_400, y: 4_064_000, cx: 10_363_200, cy: 762_000,
                    paragraphs: [deck.subtitle], size: 1800, color: "E6E9EF"),
        ])
        // 中身
        for (i, slide) in deck.slides.enumerated() {
            files["ppt/slides/slide\(i + 2).xml"] = slideXML([
                rect(id: 2, x: 0, y: 0, cx: width, cy: 101_600, color: accentHex),
                textBox(id: 3, x: 812_800, y: 508_000, cx: 10_566_400, cy: 762_000,
                        paragraphs: [slide.heading], size: 2800, bold: true, color: accentHex, anchor: "b"),
                rect(id: 4, x: 812_800, y: 1_340_000, cx: 10_566_400, cy: 19_050, color: "C5CDD9"),
                textBox(id: 5, x: 914_400, y: 1_651_000, cx: 10_363_200, cy: 4_572_000,
                        paragraphs: slide.bullets, size: 2000, color: "262626", bullets: true),
                textBox(id: 6, x: 11_176_000, y: 6_350_000, cx: 609_600, cy: 304_800,
                        paragraphs: ["\(i + 2)"], size: 1100, color: "808080"),
            ])
        }
        for n in 1...count {
            files["ppt/slides/_rels/slide\(n).xml.rels"] = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """
        }

        for (path, body) in files {
            let file = dir.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
        }
        // [Content_Types].xml を先頭に入れる（読み込むアプリによっては、これが最初にないと開けない）
        try? fm.removeItem(at: url)
        try zip(dir: dir, to: url, first: "[Content_Types].xml")
    }

    private static func zip(dir: URL, to url: URL, first: String) throws {
        for args in [["-X", "-q", url.path, first], ["-X", "-q", "-r", url.path, ".", "-x", first]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Tools.ToolError(message: "PowerPoint のファイルを作れませんでした") }
        }
    }

    private static func slideXML(_ shapes: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
        \(shapes.joined(separator: "\n"))
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func rect(id: Int, x: Int, y: Int, cx: Int, cy: Int, color: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="図形 \(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        <a:solidFill><a:srgbClr val="\(color)"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>
        """
    }

    private static func textBox(id: Int, x: Int, y: Int, cx: Int, cy: Int, paragraphs: [String], size: Int,
                                bold: Bool = false, color: String, anchor: String = "t", bullets: Bool = false) -> String {
        let runs = paragraphs.map { line -> String in
            let bullet = bullets
                ? "<a:pPr marL=\"342900\" indent=\"-342900\"><a:spcBef><a:spcPts val=\"1200\"/></a:spcBef><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>"
                : "<a:pPr><a:buNone/></a:pPr>"
            return "<a:p>\(bullet)<a:r><a:rPr lang=\"ja-JP\" sz=\"\(size)\" b=\"\(bold ? 1 : 0)\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:latin typeface=\"\(font)\"/><a:ea typeface=\"\(font)\"/></a:rPr><a:t>\(esc(line))</a:t></a:r></a:p>"
        }.joined()
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="テキスト \(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr wrap="square" anchor="\(anchor)"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(runs.isEmpty ? "<a:p/>" : runs)</p:txBody></p:sp>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 最低限のテーマ（色・フォント・線や塗りの決まり）。無いと PowerPoint が開けない
    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="提案書">
    <a:themeElements>
    <a:clrScheme name="提案書">
    <a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
    <a:dk2><a:srgbClr val="1C3A6B"/></a:dk2><a:lt2><a:srgbClr val="E6E9EF"/></a:lt2>
    <a:accent1><a:srgbClr val="1C3A6B"/></a:accent1><a:accent2><a:srgbClr val="3E6FB0"/></a:accent2>
    <a:accent3><a:srgbClr val="7A9CC6"/></a:accent3><a:accent4><a:srgbClr val="C9862B"/></a:accent4>
    <a:accent5><a:srgbClr val="5B8C5A"/></a:accent5><a:accent6><a:srgbClr val="A94442"/></a:accent6>
    <a:hlink><a:srgbClr val="3E6FB0"/></a:hlink><a:folHlink><a:srgbClr val="7A5C99"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="提案書">
    <a:majorFont><a:latin typeface="Hiragino Sans"/><a:ea typeface="Hiragino Sans"/><a:cs typeface=""/></a:majorFont>
    <a:minorFont><a:latin typeface="Hiragino Sans"/><a:ea typeface="Hiragino Sans"/><a:cs typeface=""/></a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="提案書">
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme>
    </a:themeElements>
    </a:theme>
    """
}
