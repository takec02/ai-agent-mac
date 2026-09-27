import AppKit
import Foundation
import UserNotifications

/// 決まった時刻や間隔で、頼まれたことを自分で実行し、知らせることがあるときだけ声をかける。
/// 何も無ければ黙る（「なし」とだけ答えさせて、その場合は表示も読み上げもしない）
struct ScheduledTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var enabled = false
    /// 分ごとに繰り返す（nil なら決まった時刻に1回）
    var everyMinutes: Int?
    var hour = 8
    var minute = 0
    /// 毎月この日に実行する（nil なら毎日）
    var dayOfMonth: Int?
    /// AI にやってもらうこと
    var prompt = ""
    var speak = true
    var notify = true
    var lastRun: Date?

    var scheduleLabel: String {
        if let m = everyMinutes {
            return m % 60 == 0 && m >= 60 ? "\(m / 60)時間ごと" : "\(m)分ごと"
        }
        if let day = dayOfMonth { return String(format: "毎月%d日 %d:%02d", day, hour, minute) }
        return String(format: "毎日 %d:%02d", hour, minute)
    }

    /// 既定で用意しておく例（どれも最初はオフ。使うものだけオンにする）
    static let samples: [ScheduledTask] = [
        ScheduledTask(name: "朝の読み上げ", hour: 8, minute: 0,
                  prompt: "今日の日付、今日の予定、今日の天気（現在地の都道府県）を調べて、40秒くらいで読み上げる文章にまとめて。予定が無ければ「予定はありません」と言う。"),
        ScheduledTask(name: "新着メールの確認", everyMinutes: 30,
                  prompt: "未読のメールを確認して、すぐ返事が要るものだけを3件まで、差出人と用件を一言で挙げて。急ぎのものが無ければ、何も言わず静かにしている。"),
        ScheduledTask(name: "次の予定の知らせ", everyMinutes: 15,
                  prompt: "これから30分以内に始まる予定があれば、開始時刻と件名を伝えて。無ければ、何も言わず静かにしている。"),
    ]
}

@MainActor
@Observable
final class Scheduler {
    private(set) var rules: [ScheduledTask] = []
    private var timer: Timer?
    private var running = false
    private unowned let agent: AgentController

    init(agent: AgentController) {
        self.agent = agent
        rules = Self.load()
    }

    // MARK: 保存

    private static let key = "watchRules"

    private static func load() -> [ScheduledTask] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return ScheduledTask.samples }
        // 以前の言い回し（「なし」とだけ答える）を、今の言い方に直す
        return saved.map { rule in
            var r = rule
            r.prompt = r.prompt.replacingOccurrences(of: "「なし」とだけ答える", with: "何も言わず静かにしている")
            return r
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func update(_ rule: ScheduledTask) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        save()
    }

    func remove(_ rule: ScheduledTask) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func addNew() -> ScheduledTask {
        let rule = ScheduledTask(name: "新しい定期実行", everyMinutes: 60, prompt: "")
        rules.append(rule)
        save()
        return rule
    }

    // MARK: 実行

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !running, let rule = rules.first(where: { isDue($0, now: Date()) }) else { return }
        // 話している最中や会議の記録中は邪魔をしない。次の確認のときにやり直す
        guard agent.state == .idle, !agent.meeting.isRecording, agent.pendingConfirmation == nil else { return }
        Task { await run(rule) }
    }

    /// 今これを実行すべきか
    func isDue(_ rule: ScheduledTask, now: Date) -> Bool {
        guard rule.enabled, !rule.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let cal = Calendar.current
        if let minutes = rule.everyMinutes {
            guard let last = rule.lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(max(1, minutes) * 60)
        }
        // 毎月の決まった日。その日でなければ動かさない（月末が短い月は、最終日に回す）
        if let day = rule.dayOfMonth {
            let today = cal.component(.day, from: now)
            let lastDay = cal.range(of: .day, in: .month, for: now)?.count ?? 31
            guard today == min(day, lastDay) else { return false }
        }
        // 決まった時刻を過ぎていて、今日まだ実行していなければ
        guard let today = cal.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: now), now >= today else { return false }
        guard let last = rule.lastRun else { return true }
        return last < today
    }

    private func run(_ rule: ScheduledTask) async {
        running = true
        defer { running = false }
        var updated = rule
        updated.lastRun = Date()
        update(updated)
        Log.write("watch run: \(rule.name)")

        let instruction = """
        これは利用者に頼まれていない、決まった時刻の自動実行です。
        次のことを確かめてください: \(rule.prompt)
        知らせる必要がなければ、説明や前置きを付けず「なし」の一語だけを返してください（この一語は読み上げられません）。
        知らせることがあるときは、話し言葉で簡潔に伝えてください。
        """
        let text = await agent.askQuietly(instruction)
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !Self.isNothing(answer) else {
            Log.write("watch: nothing to report (\(rule.name))")
            return
        }
        agent.deliver(answer, from: rule)
    }

    /// 「なし」「特にありません」など、知らせることが無いという答えか
    static func isNothing(_ text: String) -> Bool {
        let t = text.replacingOccurrences(of: "。", with: "").replacingOccurrences(of: "、", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 24 { return false }
        let patterns = ["^なし$", "特に(ありません|ない|無し|なし)", "^ありません$", "知らせること(は)?(ありません|ない)",
                        "^(該当|対象)(は)?(ありません|なし)", "^(no|none|nothing)$",
                        "何も(言わ|申し上げ|お知らせ)", "静かにして"]
        return patterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

// MARK: 通知

enum Notifier {
    /// 通知の許可を一度だけ求める（断られてもアプリは動く）
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Log.write("notification permission: \(error.localizedDescription)") }
        }
    }

    static func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
