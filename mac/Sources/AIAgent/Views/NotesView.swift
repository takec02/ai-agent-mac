import AppKit
import SwiftUI

/// 議事録を読むための別ウィンドウ。
/// 上に要約・決定事項・宿題、下に文字起こし（必要なときだけ開く）
struct NotesView: View {
    @Environment(AgentController.self) private var agent
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var note = Note(text: "")
    @State private var summarizing = false
    @State private var message: String?
    @State private var showTranscript = false

    /// 議事録1件分。要約の部分と文字起こしの部分に分けて持つ
    struct Note {
        var text: String
        var sections: [(title: String, lines: [String])] {
            var result: [(String, [String])] = []
            var title = ""
            var lines: [String] = []
            for line in text.components(separatedBy: .newlines) {
                if line.hasPrefix("## ") {
                    if !title.isEmpty || !lines.isEmpty { result.append((title, lines)) }
                    title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    lines = []
                } else if line.hasPrefix("# ") {
                    continue  // ファイル全体の見出しは、画面の上に別に出す
                } else {
                    lines.append(line)
                }
            }
            if !title.isEmpty || !lines.isEmpty { result.append((title, lines)) }
            return result.filter { !$0.0.isEmpty || !$0.1.joined().trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var hasSummary: Bool { text.contains("## 要約") }
        var transcript: [String] {
            (sections.first { $0.title.contains("文字起こし") }?.lines ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        var summarySections: [(title: String, lines: [String])] {
            sections.filter { !$0.title.contains("文字起こし") }
        }
    }

    var body: some View {
        HSplitView {
            list
            detail
        }
        .frame(minWidth: 760, minHeight: 460)
        .task { reload() }
    }

    private var list: some View {
        List(files, id: \.self, selection: $selected) { url in
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: url)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(date(of: url))
                    if hasSummary(url) {
                        Text("要約あり").foregroundStyle(.tint)
                    } else {
                        Text("要約なし").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(url)
        }
        .frame(minWidth: 230, maxWidth: 300)
        .onChange(of: selected) { _, new in load(new) }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected.map(title(of:)) ?? "議事録").font(.headline)
                Spacer()
                if summarizing {
                    ProgressView().controlSize(.small)
                    Text("要約しています…（数十秒）").font(.caption).foregroundStyle(.secondary)
                } else if selected != nil {
                    Button(note.hasSummary ? "要約を作り直す" : "要約を作る") { summarize() }
                        .disabled(note.transcript.isEmpty)
                        .help(note.transcript.isEmpty ? "文字起こしが無いため要約できません" : "")
                }
                Button("Finder で開く") { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } }
                    .disabled(selected == nil)
                Button("更新") { reload() }
            }
            .padding(12)
            Divider()
            if let message {
                Text(message)
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if note.summarySections.isEmpty {
                        Text(note.transcript.isEmpty
                             ? "この議事録には中身がありません。"
                             : "まだ要約がありません。右上の「要約を作る」を押すと作れます。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(note.summarySections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.title3.weight(.semibold))
                            }
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    Text(trimmed.hasPrefix("-") ? "・" + trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if !note.transcript.isEmpty {
                        Divider()
                        DisclosureGroup(isExpanded: $showTranscript) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(note.transcript.enumerated()), id: \.offset) { _, line in
                                    Text(line.hasPrefix("-") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("文字起こし（\(note.transcript.count)行）").font(.headline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func title(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    private func date(of url: URL) -> String {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func hasSummary(_ url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("## 要約")
    }

    private func reload() {
        let all = (try? FileManager.default.contentsOfDirectory(at: MeetingRecorder.folder,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        files = all.filter { $0.pathExtension == "md" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        if selected == nil || !files.contains(selected!) { selected = files.first }
        load(selected)
    }

    private func load(_ url: URL?) {
        message = nil
        showTranscript = false
        guard let url else {
            note = Note(text: "")
            return
        }
        note = Note(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func summarize() {
        guard let url = selected else { return }
        summarizing = true
        message = nil
        Task {
            do {
                try await agent.summarizeNotes(at: url)
                load(url)
            } catch {
                message = "要約を作れませんでした: \(error.localizedDescription)"
            }
            summarizing = false
        }
    }
}
