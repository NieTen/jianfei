import XCTest

final class RecordingFlowUITests: XCTestCase {
    @MainActor
    func testOnboardingWeightReentryManualCaloriesAndPhotoPicker() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // 独立本地身份，不连接真实后台、不触碰使用者的记录。
        app.launchArguments = ["-local_namespace", "ui-" + UUID().uuidString.lowercased(),
                               "-setup_completed", "NO", "-sync_enabled", "NO",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textFields["年龄"].waitForExistence(timeout: 30))
        app.textFields["年龄"].tap()
        app.textFields["年龄"].typeText("30")
        app.textFields["身高"].tap()
        app.textFields["身高"].typeText("175")
        app.textFields["weight.amount"].tap()
        app.textFields["weight.amount"].typeText("70")
        app.segmentedControls.buttons["男性"].tap()
        app.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["平时活动多吗？"].waitForExistence(timeout: 10))
        app.buttons["继续"].tap()
        XCTAssertTrue(app.buttons["暂不连接，开始记录"].waitForExistence(timeout: 10))
        app.buttons["暂不连接，开始记录"].tap()
        XCTAssertTrue(app.buttons["dashboard.weight"].waitForExistence(timeout: 20))
        app.buttons["dashboard.weight"].tap()
        let weight = app.textFields["weight.amount"]
        XCTAssertTrue(weight.waitForExistence(timeout: 10))
        XCTAssertEqual(weight.value as? String, "70")
        XCTAssertTrue(app.staticTexts["重量"].exists)
        weight.tap()
        weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "71")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["dashboard.weight"].waitForExistence(timeout: 10))
        app.buttons["dashboard.weight"].tap()
        XCTAssertTrue(weight.waitForExistence(timeout: 10))
        XCTAssertEqual(weight.value as? String, "71")
        app.navigationBars.buttons["取消"].tap()
        app.buttons["dashboard.meal"].tap()
        XCTAssertTrue(app.buttons["meal.type.lunch"].waitForExistence(timeout: 10))
        app.buttons["meal.type.lunch"].tap()
        XCTAssertTrue(app.buttons["meal.type.lunch"].isSelected)
        app.segmentedControls.buttons["手动热量"].tap()
        let calories = app.textFields["meal.calories"]
        XCTAssertTrue(calories.waitForExistence(timeout: 10))
        calories.tap()
        calories.typeText("650")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["dashboard.meal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["650"].exists)
        app.buttons["dashboard.meal"].tap()
        XCTAssertTrue(app.buttons["meal.photos"].waitForExistence(timeout: 10))
        app.buttons["meal.photos"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "点击相册应打开系统照片选择器")
        let addButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '添加' OR label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addButton.exists, "多选照片选择器应提供添加操作")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "相册入口实际点击"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(app.buttons["meal.photos"].waitForExistence(timeout: 10))
    }
}
