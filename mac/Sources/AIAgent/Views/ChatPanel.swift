import SwiftUI

/// メイン画面の右に出す、会話の履歴。
/// 中央の流れる表示は数件で消えていくので、ここでは今の会話を全部、読みやすい白地で残しておく
struct ChatPanel: View {
    let entries: [ConversationEntry]
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会話の履歴")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(entries.filter { $0.role != "system" }.count) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
            .padding(.bottom, 10)
            Divider()

            if entries.isEmpty {
                Text("話しかけると、ここにやりとりが残ります。\nゴミ箱のボタンで消えます。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(entries) { entry in
                                ChatRow(entry: entry, name: name).id(entry.id)
                            }
                        }
                        .padding(14)
                    }
                    // 新しい発言や、読み上げ中に伸びていく返事を追いかける
                    .onChange(of: entries.last?.id) { scrollToEnd(proxy) }
                    .onChange(of: entries.last?.text) { scrollToEnd(proxy) }
                    .onAppear { scrollToEnd(proxy, animated: false) }
                }
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = entries.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct ChatRow: View {
    let entry: ConversationEntry
    let name: String

    var body: some View {
        switch entry.role {
        case "user": bubble(alignment: .trailing, who: "あなた", fill: Color(red: 0.86, green: 0.92, blue: 1.0))
        case "assistant": bubble(alignment: .leading, who: name, fill: Color(white: 0.94))
        default:
            // 「止めました」「確認」などのお知らせは、小さく真ん中に
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        }
    }

    private func bubble(alignment: HorizontalAlignment, who: String, fill: Color) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text("\(who)  \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(entry.text.isEmpty ? "…" : entry.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12).fill(fill))
        }
        .frame(maxWidth: 270, alignment: alignment == .trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}
