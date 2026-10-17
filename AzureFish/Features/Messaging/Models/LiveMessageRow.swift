struct LiveMessageRow: Sendable, Hashable {
    let id: String
    let text: String
    let sender: String
    let status: String
    let outgoing: Bool
    let sequence: Int64
    var systemNotice = false
    var revoked = false
    var canReedit = false
}
