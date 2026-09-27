import Contacts
import Foundation

/// Mac の「連絡先」を読み書きする。電話番号・メール・誕生日・会社を答えたり、
/// 名刺から読み取った内容を登録したりするのに使う
@MainActor
enum ContactsBook {
    private static let store = CNContactStore()

    private static let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactNoteKey,
        CNContactPostalAddressesKey,
    ].map { $0 as CNKeyDescriptor }

    /// 読み書きの許可を求める（初回だけダイアログが出る）
    static func requestAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return
        case .notDetermined:
            guard try await store.requestAccess(for: .contacts) else { throw denied() }
        default: throw denied()
        }
    }

    private static func denied() -> Tools.ToolError {
        Tools.ToolError(message: "連絡先の使用が許可されていません（システム設定 → プライバシーとセキュリティ → 連絡先）")
    }

    // MARK: 探す

    static func find(_ query: String) async throws -> String {
        try await requestAccess()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw Tools.ToolError(message: "探したい名前を教えてください") }
        let request = CNContactFetchRequest(keysToFetch: keys)
        var found: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, stop in
            if matches(contact, text) { found.append(contact) }
            if found.count >= 5 { stop.pointee = true }
        }
        guard !found.isEmpty else { return "「\(text)」に当てはまる連絡先は見つかりませんでした" }
        return found.map(describe).joined(separator: "\n\n")
    }

    private static func matches(_ contact: CNContact, _ query: String) -> Bool {
        let haystack = [contact.familyName, contact.givenName, contact.organizationName, contact.jobTitle,
                        contact.emailAddresses.map { $0.value as String }.joined(separator: " ")]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains(query.lowercased())
    }

    /// 読み上げやすい1件分の説明
    private static func describe(_ contact: CNContact) -> String {
        var lines: [String] = []
        let name = [contact.familyName, contact.givenName].filter { !$0.isEmpty }.joined(separator: " ")
        lines.append(name.isEmpty ? "（名前なし）" : name)
        let work = [contact.organizationName, contact.jobTitle].filter { !$0.isEmpty }.joined(separator: " / ")
        if !work.isEmpty { lines.append(work) }
        for phone in contact.phoneNumbers {
            lines.append("電話: \(phone.value.stringValue)")
        }
        for mail in contact.emailAddresses {
            lines.append("メール: \(mail.value as String)")
        }
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            let year = birthday.year.map { "\($0)年" } ?? ""
            lines.append("誕生日: \(year)\(month)月\(day)日")
        }
        if !contact.note.isEmpty { lines.append("メモ: \(contact.note)") }
        return lines.joined(separator: "\n")
    }

    // MARK: 誕生日

    /// これから days 日以内に誕生日を迎える人
    static func birthdays(within days: Int) async throws -> String {
        try await requestAccess()
        let request = CNContactFetchRequest(keysToFetch: keys)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var found: [(days: Int, text: String)] = []
        try store.enumerateContacts(with: request) { contact, _ in
            guard let birthday = contact.birthday, let month = birthday.month, let day = birthday.day else { return }
            var components = DateComponents(month: month, day: day)
            components.year = calendar.component(.year, from: today)
            guard var next = calendar.date(from: components) else { return }
            if next < today { next = calendar.date(byAdding: .year, value: 1, to: next) ?? next }
            let diff = calendar.dateComponents([.day], from: today, to: next).day ?? 0
            guard diff <= days else { return }
            let name = [contact.familyName, contact.givenName].filter { !$0.isEmpty }.joined(separator: " ")
            let when = diff == 0 ? "今日" : "\(month)月\(day)日（あと\(diff)日）"
            found.append((diff, "\(when): \(name.isEmpty ? "（名前なし）" : name)"))
        }
        guard !found.isEmpty else { return "\(days)日以内に誕生日の人はいません" }
        return found.sorted { $0.days < $1.days }.map(\.text).joined(separator: "\n")
    }

    // MARK: 登録

    struct NewContact {
        var familyName = ""
        var givenName = ""
        var organization = ""
        var jobTitle = ""
        var phones: [String] = []
        var emails: [String] = []
        var note = ""
    }

    /// 連絡先に1件追加する（呼ぶ前に必ず利用者へ確認すること）
    static func save(_ new: NewContact) async throws -> String {
        try await requestAccess()
        let contact = CNMutableContact()
        contact.familyName = new.familyName
        contact.givenName = new.givenName
        contact.organizationName = new.organization
        contact.jobTitle = new.jobTitle
        contact.phoneNumbers = new.phones.filter { !$0.isEmpty }.map {
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: $0))
        }
        contact.emailAddresses = new.emails.filter { !$0.isEmpty }.map {
            CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
        }
        contact.note = new.note
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw Tools.ToolError(message: "連絡先に登録できませんでした: \(error.localizedDescription)")
        }
        let name = [new.familyName, new.givenName].filter { !$0.isEmpty }.joined(separator: " ")
        Log.write("contact saved: \(name.isEmpty ? "（名前なし）" : name)")
        return "連絡先に登録しました: \(name)\(new.organization.isEmpty ? "" : "（\(new.organization)）")"
    }
}

// MARK: 名刺アプリからの書き出し（CSV）を取り込む

extension ContactsBook {
    /// CSV の1行を、連絡先1件に直す。列の名前で見分ける（Eight・myBridge・Excel など、見出しがあるもの向け）
    static func parseCSV(_ text: String) -> [NewContact] {
        let rows = csvRows(text)
        guard let header = rows.first, rows.count > 1 else { return [] }
        /// 見出しの名前で列を探す。完全一致を先に見て、無ければ部分一致（「氏名」が「名」に当たらないように）
        func column(_ exact: [String], contains: [String] = []) -> Int? {
            func clean(_ cell: String) -> String {
                cell.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "").lowercased()
            }
            if let i = header.firstIndex(where: { exact.contains(clean($0)) }) { return i }
            guard !contains.isEmpty else { return nil }
            return header.firstIndex { cell in contains.contains { clean(cell).contains($0) } }
        }
        /// 同じ種類の列が複数あるとき（電話番号と携帯電話）は、すべて集める
        func columns(_ contains: [String]) -> [Int] {
            header.indices.filter { i in
                let name = header[i].replacingOccurrences(of: " ", with: "").lowercased()
                return contains.contains { name.contains($0) }
            }
        }
        let family = column(["姓", "lastname", "familyname", "last name"])
        let given = column(["名", "firstname", "givenname", "first name"])
        let full = column(["氏名", "名前", "fullname", "name"], contains: ["氏名", "名前"])
        let company = column(["会社名", "会社", "company", "organization", "勤務先"], contains: ["会社", "company", "勤務先"])
        let title = column(["役職", "title"], contains: ["役職", "部署", "department", "title"])
        let phones = columns(["電話", "tel", "phone", "携帯", "mobile", "fax"]).filter { header[$0].lowercased().contains("fax") == false }
        let emails = columns(["メール", "mail"])
        let note = column(["メモ", "note", "備考"], contains: ["メモ", "note", "備考"])

        return rows.dropFirst().compactMap { row in
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            func values(_ indexes: [Int]) -> [String] {
                indexes.compactMap { $0 < row.count ? row[$0] : nil }
                    .flatMap { $0.split(whereSeparator: { ",、，/;".contains($0) }) }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            var new = NewContact()
            new.familyName = value(family)
            new.givenName = value(given)
            if new.familyName.isEmpty, new.givenName.isEmpty {
                // 「山田 太郎」「佐藤, 花子」のように1列の場合は、空白か読点で分ける
                let whole = value(full)
                let parts = whole.split(whereSeparator: { $0 == " " || $0 == "　" || $0 == "," || $0 == "、" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                new.familyName = parts.first ?? whole
                new.givenName = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
            }
            new.organization = value(company)
            new.jobTitle = [value(title), title.map { _ in "" } ?? ""].filter { !$0.isEmpty }.joined()
            // 部署と役職が別の列にある場合は、両方つなげる
            let department = header.indices.first { header[$0].contains("部署") || header[$0].lowercased().contains("department") }
            let position = header.indices.first { header[$0].contains("役職") || header[$0].lowercased().contains("title") }
            new.jobTitle = [value(department), value(position)].filter { !$0.isEmpty }.joined(separator: " ")
            new.phones = values(phones)
            new.emails = values(emails)
            new.note = value(note)
            let hasName = !(new.familyName + new.givenName + new.organization).isEmpty
            return hasName ? new : nil
        }
    }

    /// 引用符つきのセルにも対応した、簡単な CSV の読み取り
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(c)
                }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",":
                row.append(cell)
                cell = ""
            case "\n", "\r":
                if !cell.isEmpty || !row.isEmpty {
                    row.append(cell)
                    rows.append(row)
                    row = []
                    cell = ""
                }
            default: cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            rows.append(row)
        }
        return rows
    }

    /// CSV ファイルから、まとめて連絡先に登録する（呼ぶ前に必ず確認すること）
    static func importCSV(at url: URL) async throws -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .shiftJIS))
            ?? ""
        guard !text.isEmpty else { throw Tools.ToolError(message: "CSV を読めませんでした") }
        let people = parseCSV(text)
        guard !people.isEmpty else { throw Tools.ToolError(message: "CSV から連絡先を見つけられませんでした（1行目に「氏名」「会社」などの見出しが要ります）") }
        try await requestAccess()
        var saved = 0
        var failed: [String] = []
        for person in people {
            do {
                _ = try await save(person)
                saved += 1
            } catch {
                failed.append([person.familyName, person.givenName].joined(separator: " "))
            }
        }
        Log.write("contacts import: \(saved)件登録 / \(failed.count)件失敗")
        var message = "\(url.lastPathComponent) から \(saved)件を連絡先に登録しました"
        if !failed.isEmpty { message += "（登録できなかった人: \(failed.prefix(5).joined(separator: "、"))）" }
        return message
    }
}
