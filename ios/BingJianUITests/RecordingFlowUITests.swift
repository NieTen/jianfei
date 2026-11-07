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
        app.buttons["keyboard.dismiss"].tap()
        app.textFields["身高"].tap()
        app.textFields["身高"].typeText("175")
        app.buttons["keyboard.dismiss"].tap()
        app.textFields["weight.amount"].tap()
        app.textFields["weight.amount"].typeText("70")
        app.buttons["keyboard.dismiss"].tap()
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
        // 数字右对齐，点输入框中央会把光标放在旧值前面；从数值末尾清除。
        weight.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        weight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "71")
        XCTAssertEqual(weight.value as? String, "71")
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars.buttons["保存"].tap()
        let editorClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["记录体重"])
        XCTAssertEqual(XCTWaiter.wait(for: [editorClosed], timeout: 10), .completed, "保存后应关闭体重录入页")
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
        let intake = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '已记录摄入' AND label CONTAINS '650'")).firstMatch
        XCTAssertTrue(intake.waitForExistence(timeout: 10), "保存后首页应显示已记录摄入 650 kcal")
        app.buttons["dashboard.meal"].tap()
        XCTAssertTrue(app.buttons["meal.photos"].waitForExistence(timeout: 10))
        app.buttons["meal.photos"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "点击相册应打开系统照片选择器")
        let addButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '添加' OR label BEGINSWITH 'Add'")).firstMatch
        // 云端模拟器首次加载照片库时先显示取消按钮；等待加载完成后再检查添加操作。
        let pickerLoaded = addButton.waitForExistence(timeout: 45)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "相册入口实际点击"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(pickerLoaded, "照片库加载完成后，多选照片选择器应提供添加操作")
        cancel.tap()
        XCTAssertTrue(app.buttons["meal.photos"].waitForExistence(timeout: 10))
    }
}
