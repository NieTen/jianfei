import Foundation

enum AccountField: String, CaseIterable, Sendable {
    case username
    case password
    case displayName = "display_name"
    case enrollmentCode = "bootstrap_code"

    var requirement: String {
        switch self {
        case .username: return "用户名需为 3～64 位英文字母、数字或 . _ -"
        case .password: return "密码需为 10～128 位"
        case .displayName: return "称呼需为 1～40 个字符"
        case .enrollmentCode: return "请填写部署者提供的开户凭据"
        }
    }
}

struct AccountInput: Equatable, Sendable {
    var username: String
    var password: String
    var displayName = ""
    var code = ""

    private var normalized: AccountInput {
        // 密码保持原样，避免把用户有意输入的空格改掉。
        AccountInput(username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                     password: password, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                     code: code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func validationErrors(registration: Bool) -> [AccountField: String] {
        let input = normalized
        var errors: [AccountField: String] = [:]
        if registration {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
            if !(3...64).contains(input.username.unicodeScalars.count) || !input.username.unicodeScalars.allSatisfy(allowed.contains) {
                errors[.username] = AccountField.username.requirement
            }
            // 与后台 Python 的字符串长度一致，按 Unicode 码点统计。
            let length = input.password.unicodeScalars.count
            if !(10...128).contains(length) { errors[.password] = "密码需为 10～128 位，当前为 \(length) 位" }
            if !(1...40).contains(input.displayName.unicodeScalars.count) { errors[.displayName] = AccountField.displayName.requirement }
            if input.code.isEmpty { errors[.enrollmentCode] = AccountField.enrollmentCode.requirement }
        } else {
            if input.username.isEmpty { errors[.username] = "请输入用户名" }
            if input.password.isEmpty { errors[.password] = "请输入密码" }
        }
        return errors
    }

    func validated(registration: Bool) throws -> AccountInput {
        let errors = validationErrors(registration: registration)
        guard errors.isEmpty else {
            throw APIError(code: "INVALID_ACCOUNT_INPUT", message: "请修改标红的输入项",
                           fieldErrors: Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) }))
        }
        return normalized
    }

    func value(for field: AccountField) -> String {
        switch field {
        case .username: return username
        case .password: return password
        case .displayName: return displayName
        case .enrollmentCode: return code
        }
    }

    func updatedErrors(from previous: AccountInput, errors: [AccountField: String], registration: Bool) -> [AccountField: String] {
        var result = validationErrors(registration: registration)
        // 服务端的用户名占用、开户凭据过期等错误，只在对应字段被编辑时清除。
        for (field, message) in errors where value(for: field) == previous.value(for: field) && result[field] == nil {
            result[field] = message
        }
        return result
    }
}
