import Foundation

extension APIError {
    static func response(status: Int, object: JSONObject) -> APIError {
        let code = object.text("code", fallback: "HTTP_\(status)")
        var fields: [String: String] = [:]
        if code == "VALIDATION_FAILED" {
            for detail in object.objects("details") {
                let field = detail.text("field").split(separator: ".").last.map(String.init) ?? ""
                guard !field.isEmpty else { continue }
                fields[field] = AccountField(rawValue: field)?.requirement
                    ?? "\(field)：\(detail.text("message", fallback: "请检查此项输入"))"
            }
        }
        if code == "USERNAME_EXISTS" { fields[AccountField.username.rawValue] = "用户名已存在，请更换用户名或关闭“创建新账号”后登录" }
        if code == "INVALID_ENROLLMENT" { fields[AccountField.enrollmentCode.rawValue] = "开户凭据错误、过期或已使用，请向部署者获取新凭据" }
        return APIError(code: code, message: object.text("message", fallback: "请求未完成，请检查连接"),
                        retryable: object.flag("retryable"), fieldErrors: fields)
    }
}
