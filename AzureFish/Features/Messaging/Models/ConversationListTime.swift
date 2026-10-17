import Foundation

/// 将会话活动的 Unix 毫秒时间转换为本地日期；缺失或非正值不显示时间。
struct ConversationListTime {
    let text: String
    let accessibilityText: String

    init(milliseconds: Int64?, now: Date = Date(), locale: Locale, timeZone: TimeZone = .current) {
        guard let milliseconds, milliseconds > 0 else {
            text = ""; accessibilityText = ""
            return
        }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
        } else {
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "yMd")
        }
        text = formatter.string(from: date)
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        accessibilityText = formatter.string(from: date)
    }
}
