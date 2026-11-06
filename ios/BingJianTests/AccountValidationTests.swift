import XCTest
@testable import BingJian

final class AccountValidationTests: XCTestCase {
    func testThreeLetterFieldsOnlyRejectShortPassword() {
        let input = AccountInput(username: "abc", password: "abc", displayName: "abc", code: "test-code")
        let errors = input.validationErrors(registration: true)
        XCTAssertEqual(Set(errors.keys), [.password])
        XCTAssertTrue(errors[.password]?.contains("当前为 3 位") == true)
    }

    func testAllInvalidFieldsAreReportedTogether() {
        let input = AccountInput(username: "中文", password: "abc", displayName: "  ", code: "\n")
        let errors = input.validationErrors(registration: true)
        XCTAssertEqual(Set(errors.keys), Set(AccountField.allCases))
        XCTAssertThrowsError(try input.validated(registration: true)) { error in
            XCTAssertEqual((error as? APIError)?.fieldErrors.count, 4)
            XCTAssertFalse(error.localizedDescription.contains("连接未完成"))
        }
    }

    func testCorrectingOneFieldKeepsOtherFieldsMarked() {
        let previous = AccountInput(username: "ab", password: "abc", displayName: "", code: "")
        var corrected = previous
        corrected.password = "test-password-123"
        let errors = corrected.updatedErrors(from: previous, errors: previous.validationErrors(registration: true), registration: true)
        XCTAssertEqual(Set(errors.keys), [.username, .displayName, .enrollmentCode])
        corrected.username = "abc"
        corrected.displayName = "abc"
        corrected.code = "test-code"
        XCTAssertTrue(corrected.updatedErrors(from: previous, errors: errors, registration: true).isEmpty)
    }

    func testServerErrorClearsOnlyWhenItsFieldChanges() {
        let previous = AccountInput(username: "abc", password: "test-password-123", displayName: "abc", code: "old-code")
        var edited = previous
        edited.username = "other_user"
        let errors = edited.updatedErrors(from: previous, errors: [.username: "用户名已存在", .enrollmentCode: "开户凭据已过期"], registration: true)
        XCTAssertNil(errors[.username])
        XCTAssertEqual(errors[.enrollmentCode], "开户凭据已过期")
        let beforeCode = edited
        edited.code = "new-code"
        XCTAssertTrue(edited.updatedErrors(from: beforeCode, errors: errors, registration: true).isEmpty)
    }

    func testNormalizingAccountFieldsDoesNotChangePassword() throws {
        let input = try AccountInput(username: "  ABC\n", password: " 12345678 ", displayName: " 昵称 ", code: " test-code\n").validated(registration: true)
        XCTAssertEqual(input.username, "abc")
        XCTAssertEqual(input.displayName, "昵称")
        XCTAssertEqual(input.code, "test-code")
        XCTAssertEqual(input.password, " 12345678 ")
    }

    func testLengthBoundsMatchBackendUnicodeRules() {
        var input = AccountInput(username: String(repeating: "a", count: 64), password: String(repeating: "a", count: 128),
                                 displayName: String(repeating: "中", count: 40), code: "test-code")
        XCTAssertTrue(input.validationErrors(registration: true).isEmpty)
        input.username += "a"; input.password += "a"; input.displayName += "中"
        XCTAssertEqual(Set(input.validationErrors(registration: true).keys), [.username, .password, .displayName])
        input = AccountInput(username: "abc", password: String(repeating: "e\u{301}", count: 5), displayName: "abc", code: "test-code")
        XCTAssertTrue(input.validationErrors(registration: true).isEmpty)
    }

    func testLoginChecksEmptyFieldsWithoutApplyingRegistrationPasswordLength() throws {
        XCTAssertEqual(Set(AccountInput(username: " ", password: "").validationErrors(registration: false).keys), [.username, .password])
        XCTAssertNoThrow(try AccountInput(username: "abc", password: "abc").validated(registration: false))
    }

    func testBusinessErrorsPointToEditableFields() {
        let duplicate = APIError.response(status: 409, object: ["code": .string("USERNAME_EXISTS"), "message": .string("用户名已存在")])
        let expired = APIError.response(status: 403, object: ["code": .string("INVALID_ENROLLMENT"), "message": .string("开户凭据错误、过期或已使用")])
        XCTAssertNotNil(duplicate.fieldErrors["username"])
        XCTAssertNotNil(expired.fieldErrors["bootstrap_code"])
    }

    @MainActor
    func testHTTPValidationResponsePreservesEveryField() async throws {
        let payload: JSONObject = ["code": .string("VALIDATION_FAILED"), "message": .string("请检查输入字段"), "details": .array([
            .object(["field": .string("body.username"), "message": .string("String should match pattern")]),
            .object(["field": .string("body.password"), "message": .string("String should have at least 10 characters")]),
            .object(["field": .string("body.display_name"), "message": .string("String should have at least 1 character")])
        ])]
        let server = try LocalHTTPTestServer(status: 422, body: JSONEncoder().encode(payload))
        defer { server.stop() }
        let port = try await server.start()
        let previousAddress = UserDefaults.standard.string(forKey: "server_url")
        let previousSession = KeychainStore.read("active_session")
        defer {
            UserDefaults.standard.set(previousAddress, forKey: "server_url")
            if let previousSession { try? KeychainStore.save(previousSession, key: "active_session") }
            else { KeychainStore.delete("active_session") }
        }
        let api = APIClient()
        try await api.configure("http://127.0.0.1:\(port)")
        do {
            _ = try await api.send("auth/register", method: "POST", body: [:], authenticated: false)
            XCTFail("应保留后台的 422 字段错误")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "VALIDATION_FAILED")
            XCTAssertEqual(Set(error.fieldErrors.keys), ["username", "password", "display_name"])
            XCTAssertTrue(error.localizedDescription.contains("10～128"))
            XCTAssertTrue(error.localizedDescription.contains("称呼"))
            XCTAssertFalse(error.localizedDescription.contains("连接未完成"))
        }
    }
}
