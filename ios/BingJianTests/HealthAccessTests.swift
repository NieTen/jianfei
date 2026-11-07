import HealthKit
import XCTest
@testable import BingJian

final class HealthAccessTests: XCTestCase {
    @MainActor
    func testMissingSigningEntitlementStopsAutomaticHealthAccess() {
        let previous = UserDefaults.standard.object(forKey: "health_enabled")
        defer { UserDefaults.standard.set(previous, forKey: "health_enabled") }
        UserDefaults.standard.set(true, forKey: "health_enabled")
        let manager = HealthManager()
        var notified = false
        manager.onAccessIssue = { notified = true }
        let error = NSError(domain: HKErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Missing com.apple.developer.healthkit entitlement."])
        let result = manager.reportFailure(error)
        XCTAssertEqual((result as? APIError)?.code, HealthAccessError.missingCapabilityCode)
        XCTAssertTrue(manager.accessIssue?.contains("重新签名安装") == true)
        XCTAssertTrue(notified)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "health_enabled"))
    }

    @MainActor
    func testBackgroundEntitlementDoesNotDisableForegroundReads() {
        let manager = HealthManager()
        let error = NSError(domain: HKErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Missing com.apple.developer.healthkit.background-delivery entitlement."])
        XCTAssertEqual((manager.reportFailure(error) as? APIError)?.code, "HEALTH_BACKGROUND_ENTITLEMENT")
        XCTAssertNil(manager.accessIssue)
    }

    func testNormalAuthorizationDenialIsNotMisidentifiedAsSigningFailure() {
        let denied = NSError(domain: HKErrorDomain, code: HKError.errorAuthorizationDenied.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "Authorization denied"])
        XCTAssertNil(HealthAccessError.translated(denied) as? APIError)
        let other = NSError(domain: "其他服务", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "com.apple.developer.healthkit"])
        XCTAssertNil(HealthAccessError.translated(other) as? APIError)
    }

    func testLockedDeviceAndUnavailableHealthHaveSpecificMessages() {
        let locked = HealthAccessError.translated(NSError(domain: HKErrorDomain, code: HKError.errorDatabaseInaccessible.rawValue)) as? APIError
        XCTAssertEqual(locked?.code, "HEALTH_LOCKED")
        XCTAssertTrue(locked?.retryable == true)
        let unavailable = HealthAccessError.translated(NSError(domain: HKErrorDomain, code: HKError.errorHealthDataUnavailable.rawValue)) as? APIError
        XCTAssertEqual(unavailable?.code, "HEALTH_UNAVAILABLE")
    }

    func testSimulatorCanQueryRealHealthKitAuthorizationStatus() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw XCTSkip("该测试设备不支持 HealthKit") }
        let store = HKHealthStore()
        let stepCount = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .stepCount))
        // 只查询是否需要授权，不弹出授权窗口、不读取任何健康记录。
        let status: HKAuthorizationRequestStatus = try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: [stepCount]) { status, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: status) }
            }
        }
        XCTAssertTrue(status == .shouldRequest || status == .unnecessary)
    }
}
