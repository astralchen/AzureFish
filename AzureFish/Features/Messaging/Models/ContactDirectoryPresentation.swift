import AzureFishAPI
import Foundation

/// 通讯录按显示名称的中文拼音排序，使用 A–Z 分组，其他首字符归入末尾的 `#`。
///
/// 索引不随界面语言变化；备注优先级、用户身份及账号规范化不变。
enum ContactDirectoryPresentation {
    static func sections(_ contacts: [ChatContact], query: String) -> [ContactSection] {
        let locale = Locale(identifier: "en_US_POSIX")
        let values = contacts.filter { $0.isContact && !$0.isBlocked && $0.matches(query) }.map { contact in
            var name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.applyingTransform(.mandarinToLatin, reverse: false) ?? name
            name = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: locale).uppercased(with: locale)
            let section = name.first.map { ("A"..."Z").contains($0) ? String($0) : "#" } ?? "#"
            return (contact: contact, name: name, section: section)
        }.sorted {
            let order = $0.name.compare($1.name, locale: locale)
            return order == .orderedSame ? $0.contact.peer.id < $1.contact.peer.id : order == .orderedAscending
        }
        let groups = Dictionary(grouping: values, by: \.section)
        return groups.keys.sorted {
            if $0 == "#" { return false }; if $1 == "#" { return true }
            return $0 < $1
        }.map { ContactSection(id: $0, contacts: groups[$0]!.map(\.contact)) }
    }
}
