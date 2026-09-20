import XCTest

@MainActor
final class KrisCoachUITests: XCTestCase {
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        return app
    }

    func testFivePrimaryTabsLaunch() {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["健康"].exists)
        XCTAssertTrue(app.tabBars.buttons["训练"].exists)
        XCTAssertTrue(app.tabBars.buttons["趋势"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
    }

    func testAISettingsEntryOpensWithoutExposingAStoredKey() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "4"]
        app.launch()

        let entry = app.buttons["open-ai-settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["智能建议"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["模型供应商密钥由 Kris 服务端安全管理，不会写入 App、iCloud、偏好设置或日志，也不要求用户自行申请。"].exists)
        XCTAssertFalse(app.secureTextFields["DeepSeek API Key"].exists)
        XCTAssertFalse(app.buttons["保存设置"].exists)
    }

    func testAIPlanComposerRequiresConfigurationAndSymptomConfirmation() {
        let app = makeApp()
        app.launchArguments += ["-ui-testing-no-sample-plan", "-selected-tab", "2"]
        app.launch()

        let entry = app.buttons["open-ai-plan-composer"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["候选计划"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["智能建议服务尚未连接"].exists)
        XCTAssertTrue(app.staticTexts["请先确认当前是否有影响训练的不适。"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ai-intent-picker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ai-reported-energy-picker"].exists)
        XCTAssertTrue(app.buttons["ai-data-disclosure"].exists)
        app.buttons["ai-data-disclosure"].tap()
        XCTAssertTrue(app.staticTexts["缺失数据保持未知；不会发送原始 HealthKit 样本，也不会发送准备度或恢复评分。"].exists)
        XCTAssertFalse(app.buttons["generate-ai-plan"].isEnabled)
    }

    func testLegacyAICandidateIsReadOnlyAndCannotBePublished() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "2", "-ai-candidate-fixture"]
        app.launch()

        XCTAssertTrue(app.staticTexts["旧版候选计划"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["edit-ai-plan"].exists)
        XCTAssertFalse(app.buttons["publish-ai-plan"].isEnabled)
        XCTAssertTrue(app.buttons["reject-legacy-ai-plan"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Legacy-AI-Candidate-Read-Only"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testOnboardingAllowsHealthOptionalEntry() {
        let app = makeApp()
        app.launchArguments.append("-onboarding-fixture")
        app.launch()

        XCTAssertTrue(app.staticTexts["从日常健康开始"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["健康数据受系统权限保护"].exists)
        let valueScreenshot = XCTAttachment(screenshot: app.screenshot())
        valueScreenshot.name = "Onboarding-Value"
        valueScreenshot.lifetime = .keepAlways
        add(valueScreenshot)
        app.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["连接 Apple 健康"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["健康数据由 Apple 健康自动更新"].exists)
        let healthScreenshot = XCTAttachment(screenshot: app.screenshot())
        healthScreenshot.name = "Onboarding-Health"
        healthScreenshot.lifetime = .keepAlways
        add(healthScreenshot)
        app.buttons["暂不连接，先浏览"].tap()
        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
    }

    func testCanStartTrainingAndRecordSet() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["训练"].waitForExistence(timeout: 5))
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 5))
        app.buttons["开始训练"].tap()

        let pauseResume = app.buttons["training-pause-resume"]
        XCTAssertTrue(pauseResume.waitForExistence(timeout: 5))
        pauseResume.tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["暂停时间不计入有效训练时长"].exists)
        pauseResume.tap()
        XCTAssertTrue(app.staticTexts["进行中"].waitForExistence(timeout: 2))

        let firstSet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'training-set-' AND identifier ENDSWITH '-1'")).firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["training-session-progress"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH '下一组：'")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["当前动作"].exists)
        firstSet.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'training-set-' AND identifier ENDSWITH '-2'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["组间休息"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["+30 秒"].exists)
        XCTAssertTrue(app.buttons["跳过休息"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS '重量增加 2.5 公斤'")
        ).firstMatch.exists)

        let activeScreenshot = XCTAttachment(screenshot: app.screenshot())
        activeScreenshot.name = "Training-Execution-Active"
        activeScreenshot.lifetime = .keepAlways
        add(activeScreenshot)

        app.buttons["结束训练"].tap()
        XCTAssertTrue(app.staticTexts["训练反馈"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["保存本次训练"].exists)
        XCTAssertTrue(app.buttons["discard-training-record"].exists)
        XCTAssertTrue(app.staticTexts["未填写不会被解释为无症状。"].exists)

        let feedbackScreenshot = XCTAttachment(screenshot: app.screenshot())
        feedbackScreenshot.name = "Training-Feedback"
        feedbackScreenshot.lifetime = .keepAlways
        add(feedbackScreenshot)

        app.buttons["保存本次训练"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["training-completion-receipt"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["训练已保存"].exists)
        XCTAssertTrue(app.staticTexts["1/6 组"].exists)
        XCTAssertTrue(app.staticTexts["总次数"].exists)
        XCTAssertTrue(app.staticTexts["负重容量"].exists)
        XCTAssertTrue(app.buttons["返回训练"].exists)

        let receiptScreenshot = XCTAttachment(screenshot: app.screenshot())
        receiptScreenshot.name = "Training-Completion-Receipt"
        receiptScreenshot.lifetime = .keepAlways
        add(receiptScreenshot)

        app.buttons["返回训练"].tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 3))
    }

    func testCanUsePlannedAlternativeDuringTraining() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["训练"].waitForExistence(timeout: 5))
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 5))
        app.buttons["开始训练"].tap()

        let adjustment = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'adjust-exercise-'")
        ).firstMatch
        XCTAssertTrue(adjustment.waitForExistence(timeout: 5))
        adjustment.tap()
        XCTAssertTrue(app.navigationBars["调整本次动作"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["use-planned-alternative"].exists)
        app.buttons["use-planned-alternative"].tap()
        app.buttons["save-exercise-adjustment"].tap()

        XCTAssertTrue(app.staticTexts["坐姿水平腿举"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["已调整"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '原计划 R'"
        )).firstMatch.exists)
    }

    func testCanDiscardTrainingWithoutSavingHistory() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "2"]
        app.launch()

        app.buttons["开始训练"].tap()
        XCTAssertTrue(app.buttons["结束训练"].waitForExistence(timeout: 3))
        app.buttons["结束训练"].tap()
        XCTAssertTrue(app.buttons["discard-training-record"].waitForExistence(timeout: 3))
        app.buttons["discard-training-record"].tap()
        XCTAssertTrue(app.buttons["放弃记录"].waitForExistence(timeout: 2))
        app.buttons["放弃记录"].tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["训练已保存"].exists)
    }

    func testCurrentPlanOffersManualEditingAndSmartGeneration() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "2"]
        app.launch()

        let edit = app.buttons["edit-training-plan"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["generate-training-plan"].exists)
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑计划"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["manual-plan-add-exercise"].exists)
        XCTAssertTrue(app.buttons["save-manual-plan"].exists)
    }

    func testActiveTrainingRemainsInteractiveAfterBackgroundResume() {
        let app = makeApp()
        app.launchArguments += ["-active-training-fixture", "-selected-tab", "2"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["training-session-progress"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.descendants(matching: .any)["training-session-progress"].waitForExistence(timeout: 2))
        let firstSet = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'training-set-' AND identifier ENDSWITH '-1'")
        ).firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 2))
        XCTAssertTrue(firstSet.isHittable)
    }

    func testTrainingHistoryOpensLocalReceiptDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-training-history-fixture", "-selected-tab", "3"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["trend-page-header"].waitForExistence(timeout: 5))
        let historyItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'training-history-item-'")
        ).firstMatch
        for _ in 0..<7 where !historyItem.isHittable { app.swipeUp() }
        XCTAssertTrue(historyItem.isHittable)
        historyItem.tap()
        let detail = app.descendants(matching: .any)["training-history-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["总次数"].exists)
        XCTAssertTrue(app.staticTexts["动作实绩"].exists)
        XCTAssertTrue(app.staticTexts["无不适"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Training-History-Detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHealthWorkoutsKeepActivityTypeAndOpenSystemDetails() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing", "-health-workout-history-fixture", "-selected-tab", "3",
        ]
        app.launch()

        let historyPanel = app.descendants(matching: .any)["training-history-panel"]
        for _ in 0..<8 where !historyPanel.isHittable { app.swipeUp() }
        XCTAssertTrue(historyPanel.exists)
        XCTAssertTrue(app.staticTexts["传统力量训练"].exists)
        XCTAssertTrue(app.staticTexts["跑步"].exists)

        let run = app.descendants(matching: .any)["training-history-item-fixture-health-run"]
        XCTAssertTrue(run.exists)
        run.tap()
        XCTAssertTrue(app.descendants(matching: .any)["training-history-detail"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["4.82 km"].exists)
        XCTAssertTrue(app.staticTexts["154 bpm"].exists)
        XCTAssertTrue(app.staticTexts["177 bpm"].exists)
        let source = app.descendants(matching: .any)["workout-source"]
        for _ in 0..<3 where !source.exists { app.swipeUp() }
        XCTAssertTrue(source.exists)
        let outdoor = app.descendants(matching: .any)["workout-environment"]
        XCTAssertTrue(outdoor.exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Health-Workout-Detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let delete = app.buttons["删除训练记录"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        XCTAssertTrue(app.buttons["删除记录"].waitForExistence(timeout: 2))
        app.buttons["删除记录"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["training-history-panel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["training-history-item-fixture-health-run"].exists)
    }

    func testHealthTrendAndSettingsSurfaces() {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["健康"].waitForExistence(timeout: 5))

        app.tabBars.buttons["健康"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["health-page-header"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["恢复状态"].exists)
        XCTAssertTrue(app.staticTexts["身体组成"].exists)

        XCTAssertTrue(app.tabBars.buttons["趋势"].waitForExistence(timeout: 5))

        app.tabBars.buttons["趋势"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trend-page-header"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["体重"].exists)

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-page-header"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Apple 健康"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Apple Watch'")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '管理设备、权限与隐私'"
        )).firstMatch.exists)
        let firstAuthorizationMessage = app.staticTexts["首次授权后，系统会自动更新；不需要每天手动导入。"]
        let automaticUpdateStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '自动更新已开启'")
        ).firstMatch
        XCTAssertTrue(firstAuthorizationMessage.exists || automaticUpdateStatus.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Mac 教练'")).firstMatch.exists)
    }

    func testHealthDomainOpensActionableDetail() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "1", "-readiness-evidence-fixture"]
        app.launch()

        let sleepDomain = app.buttons["health-domain-sleep"]
        XCTAssertTrue(sleepDomain.waitForExistence(timeout: 5))
        sleepDomain.tap()
        XCTAssertTrue(app.navigationBars["睡眠"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["health-domain-detail-sleep"].exists)
        XCTAssertTrue(app.staticTexts["今日睡眠"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["health-last-measurement"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["health-app-updated"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '缓存样本'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["记录点"].exists)
        XCTAssertTrue(app.buttons["在趋势中查看变化"].exists)
    }

    func testTrainingKeepsCoachingNotesCollapsedByDefault() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "2"]
        app.launch()

        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["今日动作"].exists)
        XCTAssertTrue(app.staticTexts["45° 腿举"].exists)
        XCTAssertTrue(app.buttons["training-plan-details"].exists)
        XCTAssertFalse(app.staticTexts["恢复正式下肢训练频率，保持腰盆稳定，不冲极限。"].exists)
        XCTAssertFalse(app.buttons["training-open-decision"].exists)

        app.buttons["training-plan-details"].tap()
        XCTAssertTrue(app.buttons["training-open-decision"].waitForExistence(timeout: 3))
    }

    func testSettingsHidesLegacyExportQueueFromStandaloneProduct() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "4", "-sync-queue-fixture"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["settings-page-header"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["开发导出队列"].exists)
        XCTAssertFalse(app.staticTexts["本机处理队列"].exists)
        XCTAssertFalse(app.staticTexts["本机后台处理暂时失败，请稍后重试。"].exists)
    }

    func testSettingsDoesNotExposeDevelopmentCompanion() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "4"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["settings-page-header"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Mac 教练'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["扫描配对二维码"].exists)
    }

    func testTodayPrioritizesDailyHealthWithoutDemandingTraining() {
        let app = makeApp()
        app.launchArguments += ["-readiness-evidence-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天想做什么？"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["today-state-hero"].exists)
        XCTAssertFalse(app.staticTexts["状态分"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["today-health-attention"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '数据待补齐'"
        )).firstMatch.exists)
        XCTAssertTrue(app.otherElements["today-core-metrics"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["暂无训练计划"].exists)
        XCTAssertTrue(app.staticTexts["今日活动"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["readiness-hero"].exists)
        XCTAssertLessThan(app.otherElements["today-core-metrics"].frame.minY, app.staticTexts["今日活动"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Daily-State-Home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let sleepMetric = app.buttons["today-metric-moon.fill"]
        if sleepMetric.waitForExistence(timeout: 2) {
            sleepMetric.tap()
            XCTAssertTrue(app.navigationBars["睡眠"].waitForExistence(timeout: 3))
        }
    }

    func testDailyHomeOpensTrainingFromPrimaryAction() {
        let app = makeApp()
        app.launch()
        let healthEntry = app.buttons["daily-action-recommendation"]
        XCTAssertTrue(healthEntry.waitForExistence(timeout: 8))
        healthEntry.tap()
        XCTAssertTrue(app.buttons["开始训练"].waitForExistence(timeout: 3))
    }

    func testTodayRemainsUsableWithDarkAppearanceAndAccessibilityText() {
        let app = makeApp()
        app.launchArguments += [
            "-readiness-evidence-fixture",
            "-force-dark-appearance",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["today-state-hero"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["today-core-metrics"].exists)
        XCTAssertTrue(app.tabBars.buttons["今日"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Daily-State-Dark-Accessibility-Text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTodayExplainsReadinessWithPersonalBaselines() {
        let app = makeApp()
        app.launchArguments += ["-readiness-evidence-fixture", "-selected-tab", "1"]
        app.launch()
        let recovery = app.buttons["health-recovery-overview"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        recovery.tap()
        let details = app.buttons["health-open-decision"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        for _ in 0..<5 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertTrue(app.navigationBars["决策依据"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["readiness-components"].exists)
        XCTAssertTrue(app.staticTexts["恢复信号"].exists)
        let timeline = app.staticTexts["本次决策时间线"]
        for _ in 0..<6 where !timeline.isHittable { app.swipeUp() }
        XCTAssertTrue(timeline.exists)
    }

    func testHealthHidesInternalCoverageDiagnostics() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "1", "-readiness-evidence-fixture"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["health-page-header"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["health-data-quality"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '关键指标覆盖'"
        )).firstMatch.exists)
    }

    func testTodayShowsConcretePlanRevisionChanges() {
        let app = makeApp()
        app.launchArguments += ["-plan-change-fixture", "-selected-tab", "2"]
        app.launch()

        let disclosure = app.buttons["training-plan-details"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        let details = app.buttons["training-open-decision"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        let title = app.staticTexts["相对上一修订"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["预计时长：55 → 50 分钟"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '→'")).count >= 2)
        for _ in 0..<4 where !title.isHittable { app.swipeUp() }
        XCTAssertTrue(title.isHittable)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Today-Plan-Changes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTrendsExposePeriodSummaryAndMetricSwitching() {
        let app = makeApp()
        app.launchArguments += ["-selected-tab", "3", "-readiness-evidence-fixture"]
        app.launch()

        XCTAssertTrue(app.staticTexts["周期概览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["HRV"].exists)
        XCTAssertTrue(app.buttons["恢复"].exists)
        XCTAssertTrue(app.buttons["体成分"].exists)
        XCTAssertTrue(app.buttons["活动"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["trend-metric-picker"].exists)
        XCTAssertTrue(app.buttons["HRV"].exists)

        let chart = app.descendants(matching: .any)["trend-detail-chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 3))
        let valueBeforeSelection = chart.value as? String
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.52)).tap()
        XCTAssertNotEqual(chart.value as? String, valueBeforeSelection)

        app.buttons["HRV"].tap()
        XCTAssertTrue(app.staticTexts["HRV"].exists)
        XCTAssertTrue(app.staticTexts["有效样本"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '个人基线 49.5 ms'")
        ).firstMatch.exists)

        let loadPanel = app.descendants(matching: .any)["training-load-panel"]
        for _ in 0..<6 where !loadPanel.isHittable { app.swipeUp() }
        XCTAssertTrue(loadPanel.exists)
        XCTAssertTrue(app.staticTexts["训练负荷"].exists)
        XCTAssertTrue(app.staticTexts["短期 7 日"].exists)
        XCTAssertTrue(app.staticTexts["长期 42 日"].exists)

        let historyPanel = app.descendants(matching: .any)["training-history-panel"]
        for _ in 0..<5 where !historyPanel.isHittable { app.swipeUp() }
        XCTAssertTrue(historyPanel.exists)
        XCTAssertTrue(app.staticTexts["最近训练"].exists)
        XCTAssertTrue(app.staticTexts["上肢 A · 回归"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Trends-Load-History"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
