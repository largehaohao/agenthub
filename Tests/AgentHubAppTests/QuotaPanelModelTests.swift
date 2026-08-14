import XCTest
import AgentHubQuota
@testable import AgentHubApp

@MainActor
final class QuotaPanelModelTests: XCTestCase {
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel(_ defaults: UserDefaults) -> QuotaPanelModel {
        QuotaPanelModel(service: QuotaService(sources: []), defaults: defaults)
    }

    func testStartsAtFullSize() throws {
        XCTAssertEqual(makeModel(try makeDefaults(#function)).scale, 1.0)
    }

    func testEnlargingAndShrinkingAreSymmetric() throws {
        let model = makeModel(try makeDefaults(#function))

        model.enlarge()
        model.shrink()

        XCTAssertEqual(model.scale, 1.0, accuracy: 0.0001)
    }

    func testScaleStopsAtTheBounds() throws {
        let model = makeModel(try makeDefaults(#function))

        for _ in 0..<50 { model.enlarge() }
        XCTAssertEqual(model.scale, QuotaPanelModel.scaleRange.upperBound, accuracy: 0.0001)
        XCTAssertFalse(model.canEnlarge)

        for _ in 0..<50 { model.shrink() }
        XCTAssertEqual(model.scale, QuotaPanelModel.scaleRange.lowerBound, accuracy: 0.0001)
        XCTAssertFalse(model.canShrink)
    }

    /// A zoom step that does not fit the screen is given back, and not offered
    /// again until the panel shrinks.
    func testRefusedEnlargementIsGivenBackAndNotOfferedAgain() throws {
        let model = makeModel(try makeDefaults(#function))
        model.enlarge()
        model.enlarge()
        let overflowing = model.scale

        model.refuseEnlargement()

        XCTAssertEqual(model.scale, overflowing - QuotaPanelModel.scaleStep, accuracy: 0.0001)
        XCTAssertFalse(model.canEnlarge)
        model.enlarge()
        XCTAssertEqual(model.scale, overflowing - QuotaPanelModel.scaleStep, accuracy: 0.0001)
    }

    /// Shrinking makes room again, so the discovered ceiling has to lift.
    func testShrinkingLiftsTheCeiling() throws {
        let model = makeModel(try makeDefaults(#function))
        model.enlarge()
        model.refuseEnlargement()
        XCTAssertFalse(model.canEnlarge)

        model.shrink()

        XCTAssertTrue(model.canEnlarge)
    }

    func testScaleSurvivesRelaunch() throws {
        let defaults = try makeDefaults(#function)
        let model = makeModel(defaults)
        model.enlarge()
        model.enlarge()

        XCTAssertEqual(makeModel(defaults).scale, model.scale, accuracy: 0.0001)
    }

    /// A never-set default reads as 0, which would collapse every dimension in
    /// the panel to nothing.
    func testUnsetScaleDoesNotCollapseThePanel() throws {
        let defaults = try makeDefaults(#function)
        defaults.set(0.0, forKey: "panelScale")

        XCTAssertEqual(makeModel(defaults).scale, 1.0)
    }

    /// A value written by a future version, or edited by hand, must not escape
    /// the range the buttons enforce.
    func testOutOfRangeStoredScaleIsIgnored() throws {
        let defaults = try makeDefaults(#function)
        defaults.set(9.0, forKey: "panelScale")

        XCTAssertEqual(makeModel(defaults).scale, 1.0)
    }

    /// A provider with no windows explains itself; one that is reporting does
    /// not, or the notice would contradict the numbers beside it.
    func testNoticesAreCarriedFromTheService() async throws {
        let service = QuotaService(sources: [
            .init(provider: .claude, fetch: { [] }, notice: { "signed out" }),
            .init(provider: .codex, fetch: { [Self.window] }, notice: { "unused" }),
        ])
        let model = QuotaPanelModel(service: service, defaults: try makeDefaults(#function))

        await model.load(force: true)

        XCTAssertEqual(model.notices, [.claude: "signed out"])
        XCTAssertEqual(model.rows.map(\.provider), [.codex])
    }

    nonisolated static let window = try! QuotaWindow(
        provider: .codex,
        accountID: "default",
        usedPercent: 42,
        windowDuration: 5 * 3_600,
        resetsAt: Date().addingTimeInterval(3_600),
        fetchedAt: Date(),
        source: "test"
    )
}
