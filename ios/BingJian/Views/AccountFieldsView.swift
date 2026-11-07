import SwiftUI

struct AccountFieldsView: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var displayName: String
    let registration: Bool
    let errors: [AccountField: String]

    var body: some View {
        if !errors.isEmpty {
            Label("请修改以下 \(errors.count) 项后再提交", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline).foregroundStyle(.red)
        }
        TextField(registration ? "用户名（3～64 位）" : "用户名", text: $username)
            .textContentType(.username).keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .modifier(AccountFieldStyle(message: errors[.username]))
        SecureField(registration ? "密码（10～128 位）" : "密码", text: $password)
            .textContentType(registration ? .newPassword : .password)
            .modifier(AccountFieldStyle(message: errors[.password]))
        if registration {
            TextField("称呼（1～40 个字符）", text: $displayName)
                .modifier(AccountFieldStyle(message: errors[.displayName]))
            Text("用户名只支持英文字母、数字和 . _ -；称呼可以使用中文。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AccountFieldStyle: ViewModifier {
    var message: String?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            content.padding(10)
                .background(message == nil ? Color.clear : Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(message == nil ? Color.clear : Color.red, lineWidth: 1.5))
                .accessibilityHint(message ?? "")
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
