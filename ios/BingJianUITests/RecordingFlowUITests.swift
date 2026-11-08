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
        assertOnlyCustomMenu(app)
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
        app.navigationBars.buttons["关闭"].tap()
        // 滚动到真实页面末尾，检查文字和操作区域均在自定义菜单上方。
        for tab in ["today", "meals", "trends", "community", "settings"] {
            app.buttons["tab.\(tab)"].tap()
            assertOnlyCustomMenu(app)
            let end = app.descendants(matching: .any).matching(identifier: "page.end.\(tab)").firstMatch
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            var previousEndFrame: CGRect?
            for _ in 0..<10 {
                scroll.swipeUp()
                if end.exists && end.isHittable {
                    let frame = end.frame
                    // 连续滚动后末尾位置不再变化才算到底，避免把部分可见的文字当成完整显示。
                    if let previous = previousEndFrame, abs(previous.minY - frame.minY) < 1,
                       abs(previous.height - frame.height) < 1 { break }
                    previousEndFrame = frame
                }
            }
            let bar = app.descendants(matching: .any).matching(identifier: "navigation.bottom").firstMatch
            XCTAssertTrue(bar.exists)
            XCTAssertTrue(end.exists && end.isHittable, "\(tab) 页面底部应可见")
            XCTAssertLessThanOrEqual(end.frame.maxY, bar.frame.minY, "\(tab) 页面末尾不能被菜单覆盖")
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "页面底部-\(tab)"
            image.lifetime = .keepAlways
            add(image)
        }
        // 覆盖真机反馈的复现路径：访问过的标签页再次进入，而非每页只打开一次。
        for _ in 0..<2 {
            for tab in ["today", "trends", "meals", "settings", "community", "today", "today"] {
                app.buttons["tab.\(tab)"].tap()
                assertOnlyCustomMenu(app)
            }
        }
        for tab in ["today", "trends"] {
            app.buttons["tab.\(tab)"].tap()
            assertOnlyCustomMenu(app)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "反复切换后-\(tab)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        // 保留每个标签页的导航状态，并检查进入详情、跨页返回和退回根页面时不出现第二套菜单。
        let historyLink = app.buttons["trends.weightHistory"]
        for _ in 0..<6 {
            if historyLink.exists && historyLink.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(historyLink.isHittable)
        historyLink.tap()
        XCTAssertTrue(app.navigationBars["体重记录"].waitForExistence(timeout: 10))
        assertOnlyCustomMenu(app)
        app.buttons["tab.today"].tap()
        assertOnlyCustomMenu(app)
        app.buttons["tab.trends"].tap()
        XCTAssertTrue(app.navigationBars["体重记录"].waitForExistence(timeout: 10), "返回趋势页应保留之前打开的体重历史")
        assertOnlyCustomMenu(app)
        app.navigationBars["体重记录"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["trends.weightHistory"].waitForExistence(timeout: 10))
        assertOnlyCustomMenu(app)
    }

    @MainActor
    private func assertOnlyCustomMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.descendants(matching: .any).matching(identifier: "navigation.bottom").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(menu.buttons.count, 5, "底部应只有五个自定义菜单入口", file: file, line: line)
        for tab in ["today", "meals", "trends", "community", "settings"] {
            XCTAssertTrue(app.buttons["tab.\(tab)"].isHittable, "自定义菜单入口应可点击", file: file, line: line)
        }
        XCTAssertFalse(app.tabBars.allElementsBoundByIndex.contains { $0.isHittable },
                       "系统 TabBar 不得与自定义菜单同时显示", file: file, line: line)
        XCTAssertFalse(app.tabBars.buttons.allElementsBoundByIndex.contains { $0.isHittable },
                       "系统 TabBar 不得出现第二组可点击入口", file: file, line: line)
    }
}
