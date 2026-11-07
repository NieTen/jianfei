import Foundation
import HealthKit

enum HealthAccessError {
    static let missingCapabilityCode = "HEALTH_SIGNING_ENTITLEMENT"
    static let signingMessage = "当前安装包的签名缺少健康数据授权。请用保留 HealthKit 授权的签名和描述文件重新签名安装，再回来请求权限。仅在系统设置中开启权限无法修复；手动记录仍可使用。"

    static func translated(_ error: Error) -> Error {
        let value = error as NSError
        guard value.domain == HKErrorDomain else { return error }
        let description = value.localizedDescription.lowercased()
        if description.contains("com.apple.developer.healthkit.background-delivery") {
            return APIError(code: "HEALTH_BACKGROUND_ENTITLEMENT", message: "当前签名不支持健康数据后台更新，可在应用内手动刷新。")
        }
        if description.contains("com.apple.developer.healthkit") {
            return APIError(code: missingCapabilityCode, message: signingMessage)
        }
        switch value.code {
        case HKError.errorHealthDataUnavailable.rawValue:
            return APIError(code: "HEALTH_UNAVAILABLE", message: "当前设备无法读取健康数据，仍可手动记录。")
        case HKError.errorHealthDataRestricted.rawValue:
            return APIError(code: "HEALTH_RESTRICTED", message: "系统或设备管理设置限制了健康数据访问，请检查设备限制。")
        case HKError.errorDatabaseInaccessible.rawValue:
            return APIError(code: "HEALTH_LOCKED", message: "健康数据暂时无法访问，请解锁 iPhone 后重试。", retryable: true)
        case HKError.errorAuthorizationNotDetermined.rawValue:
            return APIError(code: "HEALTH_NOT_REQUESTED", message: "请先在健康权限页面请求读取权限，再补取健康数据。")
        case HKError.errorUserCanceled.rawValue:
            return APIError(code: "HEALTH_CANCELLED", message: "已取消健康授权，你可以稍后重新请求。")
        default: return error
        }
    }
}
