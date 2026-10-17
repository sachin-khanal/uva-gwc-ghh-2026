//
// File:     WaypointUITests/WaypointUITests.swift
// Owner:    D (App/Sync/Integration) with whoever changes the screens; run by anyone with a phone.
// Purpose:  UI tests that run ON A REAL PHONE from the command line (`DEVICE=<id> make uitest`): they launch the app, tap through
//           the screens, read what is on screen (via accessibility ids set in Waypoint/UI/*), and save screenshots + text notes
//           as test attachments. `make uitest-shots` exports them to PNG/text files so a person OR an LLM agent can look at them
//           without mirroring the phone.
// Needs:    DO NOT USE THE PHONE while it runs (switching apps hides ours and fails the test: seen once as a "Navigate button missing").
//           phone plugged in + UNLOCKED, and on the phone: Settings > Developer > Enable UI Automation = On.
//           Camera/Local Network prompts are accepted automatically by the interruption monitor below.
// Limits:   cannot move the phone through space, so AR scanning/relocalization are only checked for "screen shows live HUD",
//           not for correctness. Cannot judge audio/haptics (the simulated-walk test checks the TEXT the app shows).
// Style:    one behaviour per test; ids are defined next to the views (`.accessibilityIdentifier("...")`) - keep them in sync.
//
import XCTest

final class WaypointUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "iOS permission prompt") { alert in
            for title in ["Allow", "Allow While Using App", "OK", "Allow Once"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        // Pin the classic screens: a leftover "New interface" preference on the phone (UserDefaults) would change every screen these tests drive.
        app.launchArguments += ["-ui.newInterface", "NO", "-ui.openInNavigate", "NO"]
        app.launch()
        // If something else (a notification, the person picking up the phone) pulled another app to the front, bring ours back.
        if app.state != .runningForeground { app.activate() }
        // Robustness: if the app comes up inside a mode (leftover state, an earlier launch switch), go back to Home so every test starts equal.
        let home = app.buttons["toolbar.home"]
        if home.waitForExistence(timeout: 3) { home.tap() }
    }

    // MARK: helpers

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fails the test (with `message`) unless `element` appears within `timeout`; returns it for chaining.
    @discardableResult
    private func need(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 10) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message)
        return element
    }

    private func waitUntil(_ predicateFormat: String, on element: XCUIElement, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicateFormat), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(message) (waited \(Int(timeout)) s; label now '\(element.label)')")
    }

    /// Opens Navigator, selects the bundled SAMPLE map and starts the simulated walk to Room 204.
    private func startSimulatedWalk(paused: Bool = false) {
        need(app.buttons["mode.navigate"], "Home screen missing").tap()
        // Maps are listed alphabetically; the user's own scans may come first, so pick the SAMPLE map explicitly.
        let sample = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SAMPLE'")).firstMatch
        need(sample, "SAMPLE map not listed").tap()
        need(app.buttons["nav.simulate.Room 204"], "Simulate button for Room 204 missing").tap()
        need(app.staticTexts["nav.status"], "Navigating screen did not appear")
        if paused { flip(app.switches["nav.pauseWalk"], "Pause toggle missing") } // freeze the walker: the whole walk is only ~15 s
    }

    /// Switches in this layout are wide rows: label on the left, the real switch at the far right. A plain .tap() hits the label and does nothing.
    private func flip(_ toggle: XCUIElement, _ message: String) {
        need(toggle, message).coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    // MARK: tests

    func testHomeScreenShowsBothModes() {
        need(app.buttons["mode.navigate"], "Navigate button missing")
        need(app.buttons["mode.scan"], "Scan button missing")
        need(app.buttons["toolbar.share"], "Share maps button missing")
        shot("01-home")
    }

    func testSimulatedWalkFinishesAndShowsArrival() {
        startSimulatedWalk()
        shot("10-sim-start")
        XCTAssertEqual(app.staticTexts["nav.status"].label, "Simulating walk")

        waitUntil("label == 'Simulation finished'", on: app.staticTexts["nav.status"], timeout: 60, "walk did not finish")
        shot("11-sim-finished")
        let instruction = app.staticTexts["nav.instruction"].label
        note("final-instruction", instruction)
        XCTAssertTrue(instruction.hasPrefix("arrived"), "expected 'arrived...' but got '\(instruction)'")
    }

    func testInjectedObstacleShowsStopWarning() {
        startSimulatedWalk()
        let toggle = need(app.switches["nav.injectObstacle"], "Obstacle toggle missing")
        // The Toggle's row is wide: label on the left, the actual switch at the far right. A plain .tap() hits the
        // centre (the label) and does nothing, so tap the right edge where the switch is.
        func flip() { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        flip()
        let warning = need(app.staticTexts["nav.obstacle"], "no obstacle warning after injecting one")
        XCTAssertEqual(warning.label, "STOP")
        shot("20-obstacle-stop")

        flip()
        waitUntil("exists == false", on: app.staticTexts["nav.obstacle"], timeout: 10, "warning should clear when the obstacle is removed")
        shot("21-obstacle-cleared")
    }

    func testObstacleIsNamedByTypeInTheSpokenSentence() {
        startSimulatedWalk(paused: true)
        // Default simulated obstacle is a trash can.
        flip(app.switches["nav.injectObstacle"], "Obstacle toggle missing")
        let spoken = need(app.staticTexts["nav.lastSpoken"], "nothing was spoken for the obstacle")
        waitUntil("label CONTAINS 'walk into a trash can'", on: spoken, timeout: 10, "trash can sentence")
        shot("50-trash-can")

        // Change what the obstacle is: the sentence must change with it.
        need(app.buttons["nav.obstacleKind"], "obstacle type picker missing").tap()
        need(app.buttons["wall"], "wall option missing").tap()
        waitUntil("label CONTAINS 'heading toward a wall'", on: app.staticTexts["nav.lastSpoken"], timeout: 10, "wall sentence")
        shot("51-wall")
        note("sentences", "trash can -> \(spoken.label)")
    }

    func testPhonePostureCoachSpeaksAndRecovers() {
        startSimulatedWalk(paused: true)
        need(app.buttons["nav.posture"], "posture picker missing").tap()
        need(app.buttons["tiltedDown"], "tiltedDown option missing").tap()
        let message = need(app.staticTexts["nav.postureText"], "no posture warning after the phone was tilted", timeout: 15)
        XCTAssertTrue(message.label.contains("pointing down"), "got: \(message.label)")
        waitUntil("label CONTAINS 'pointing down'", on: app.staticTexts["nav.lastSpoken"], timeout: 10, "the user must HEAR it, not just see it")
        shot("60-posture-bad")

        need(app.buttons["nav.posture"], "posture picker missing").tap()
        need(app.buttons["good"], "good option missing").tap()
        waitUntil("label CONTAINS 'Phone position is good'", on: app.staticTexts["nav.recentSpeech"], timeout: 15, "recovery message")
        waitUntil("exists == false", on: app.staticTexts["nav.postureText"], timeout: 10, "warning text should clear")
        shot("61-posture-good")
    }

    /// New Scanner > "Extend a map" must really start an extension (not the old "Coming soon" sheet): pick a saved scan, and the scanner
    /// says it is looking for its place in that scan, with Finish disabled. Needs a real scan with saved position data on the phone.
    func testNewScannerExtendMapStartsFindingPlaceInSavedScan() throws {
        app.terminate()
        app.launchArguments = ["-ui.newInterface", "YES", "-ui.serviceMode", "live"]
        app.launch()
        if app.state != .runningForeground { app.activate() }
        need(app.buttons["mode.scan"], "Scan button missing").tap()
        let extend = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Extend a map'")).firstMatch
        need(extend, "Extend a map button missing").tap()
        shot("70-extend-picker")
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Scanned area' OR label CONTAINS 'Scan area '")).firstMatch
        guard saved.waitForExistence(timeout: 5) else { throw XCTSkip("no scan with saved position data on this phone") }
        saved.tap()
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'saved area' OR label CONTAINS 'scanned area' OR label CONTAINS 'Extending this building' OR label CONTAINS 'previously scanned'")).firstMatch
        need(status, "scanner never said it is looking for its place in the saved scan", timeout: 20)
        note("extension-status", status.label)
        shot("71-extend-looking")
        let finish = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Finish'")).firstMatch
        need(finish, "Finish button missing")
        if status.label.contains("saved area") || status.label.contains("scanned area") || status.label.contains("previously scanned") {
            XCTAssertFalse(finish.isEnabled, "Finish must stay disabled until the scan has found its place in the old map")
        }
    }

    /// Classic scan screen: the "unscanned areas" toggle exists, starts OFF and flips. (The overlay itself needs a real mesh, which a phone
    /// lying on a desk does not build; the geometry is unit-tested and `-scanCoverage YES` logs it headlessly.)
    func testUnscannedAreasToggleExistsAndFlips() {
        need(app.buttons["mode.scan"], "Scan button missing").tap()
        need(app.buttons["scan.start"], "Start scanning button missing").tap()
        need(app.staticTexts["hud.tracking"], "live HUD never appeared", timeout: 20)
        let toggle = need(app.switches["scan.coverage"], "unscanned-areas toggle missing")
        XCTAssertEqual(toggle.value as? String, "0", "must start off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitUntil("value == '1'", on: toggle, timeout: 5, "toggle did not turn on")
    }

    /// New Scanner (live mode): Pause turns into Resume, and the coverage toggle is in the expanded controls.
    func testNewScannerPauseAndCoverageToggle() throws {
        app.terminate()
        app.launchArguments = ["-ui.newInterface", "YES", "-ui.serviceMode", "live"]
        app.launch()
        if app.state != .runningForeground { app.activate() }
        need(app.buttons["mode.scan"], "Scan button missing").tap()
        let newScan = app.buttons.matching(NSPredicate(format: "label CONTAINS 'New scan'")).firstMatch
        need(newScan, "New scan button missing").tap()
        let building = need(app.textFields["Building"], "building field missing")
        building.tap(); building.typeText("UITest Hall")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Start scanning'")).firstMatch.tap()
        let pause = need(app.buttons["Pause"], "Pause button missing", timeout: 20)
        pause.tap()
        need(app.buttons["Resume"], "Pause did not turn into Resume")
        shot("80-new-scanner-paused")
        app.buttons["Resume"].tap()
        need(app.buttons["Pause"], "Resume did not turn back into Pause")
        // expand the panel to reach the toggle
        if app.buttons["Expand controls"].exists { app.buttons["Expand controls"].tap() } // it may already be open
        let coverage = need(app.switches["scan.coverage"], "unscanned-areas toggle missing in the new Scanner")
        XCTAssertEqual(coverage.value as? String, "0")
        shot("81-new-scanner-expanded")
    }

    func testScanScreenShowsLiveHUD() {
        need(app.buttons["mode.scan"], "Scan button missing").tap()
        need(app.buttons["scan.start"], "Start scanning button missing").tap()

        let tracking = need(app.staticTexts["hud.tracking"], "live HUD never appeared (camera permission? AR unsupported?)", timeout: 20)
        Thread.sleep(forTimeInterval: 10) // let ARKit build some mesh
        let box = app.staticTexts["hud.box"]
        let report = [
            "tracking: \(tracking.label)",
            "mapping:  \(app.staticTexts["hud.mapping"].label)",
            "mesh:     \(app.staticTexts["hud.mesh"].label)",
            "box:      \(box.exists ? box.label : "(no box yet)")",
        ].joined(separator: "\n")
        note("hud-values", report)
        shot("30-scan-hud")
        XCTAssertTrue(app.staticTexts["hud.mapping"].exists)
        XCTAssertTrue(app.staticTexts["hud.mesh"].exists)
        app.buttons["toolbar.home"].tap() // leaving the screen stops the AR session
    }

    func testShareMapsSheetShowsCloudSection() {
        need(app.buttons["toolbar.share"], "Share maps button missing").tap()
        need(app.navigationBars["Share maps"], "Share maps sheet did not open")
        let cloud = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Cloud library'")).firstMatch
        need(cloud, "Cloud library section missing")
        shot("40-share-sheet")
        app.buttons["Done"].tap()
    }
}
