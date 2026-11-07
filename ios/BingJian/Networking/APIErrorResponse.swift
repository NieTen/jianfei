import Foundation

extension APIError {
    static func response(status: Int, object: JSONObject) -> APIError {
        let code = object.text("code", fallback: "HTTP_\(status)")
        if code == "INVALID_ENROLLMENT" || (code == "VALIDATION_FAILED" && object.objects("details").contains(where: { $0.text("field") == "body.bootstrap_code" })) {
            return APIError(code: "SERVER_REGISTRATION_UPGRADE", message: "当前后台仍要求开户凭据，请更新 NAS 后台后再注册。")
        }
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
        return APIError(code: code, message: object.text("message", fallback: "请求未完成，请检查连接"),
                        retryable: object.flag("retryable"), fieldErrors: fields)
    }
}
