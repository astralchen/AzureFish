import Foundation

/// 表单校验遵循服务端契约；密码和用户资料不会在此规范化。
enum AccountValidation {
    static func account(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (3...32).contains(value.utf8.count) && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
    static func password(_ value: String) -> Bool {
        value.count >= 12 && value.utf8.count <= 72 && !value.contains("\0")
    }
    static func nickname(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 64 && text(value)
    }
    static func bio(_ value: String) -> Bool { value.count <= 500 && text(value) }
    /// 检查自由文本是否含换行以外的控制字符；长度和非空约束由具体业务单独检查。
    static func text(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }
}
