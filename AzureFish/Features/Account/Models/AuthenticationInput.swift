/// 保留原始输入供同一次失败提交重试，生命周期限于当前表单内存。
struct AuthenticationInput: Equatable {
    let register: Bool
    let account: String
    let password: String
    let nickname: String
}
