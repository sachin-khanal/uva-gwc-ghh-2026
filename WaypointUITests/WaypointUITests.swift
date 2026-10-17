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
    private func startSimulatedWalk() {
        need(app.buttons["mode.navigate"], "Home screen missing").tap()
        // Maps are listed alphabetically; the user's own scans may come first, so pick the SAMPLE map explicitly.
        let sample = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SAMPLE'")).firstMatch
        need(sample, "SAMPLE map not listed").tap()
        need(app.buttons["nav.simulate.Room 204"], "Simulate button for Room 204 missing").tap()
        need(app.staticTexts["nav.status"], "Navigating screen did not appear")
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
