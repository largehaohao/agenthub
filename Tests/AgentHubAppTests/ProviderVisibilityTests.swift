import XCTest
import AgentHubQuota
@testable import AgentHubApp

@MainActor
final class ProviderVisibilityTests: XCTestCase {
    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Nothing stored is a first run, not "everything hidden".
    func testEverythingIsShownBeforeAnyChoiceIsMade() throws {
        let visibility = ProviderVisibility(defaults: try makeDefaults(#function))

        XCTAssertEqual(visibility.shown, Set(Provider.allCases))
        for provider in Provider.allCases {
            XCTAssertTrue(visibility.isShown(provider))
        }
    }

    func testHidingAndShowingAProvider() throws {
        let visibility = ProviderVisibility(defaults: try makeDefaults(#function))

        visibility.setShown(.cursor, false)
        XCTAssertFalse(visibility.isShown(.cursor))
        XCTAssertTrue(visibility.isShown(.claude))

        visibility.setShown(.cursor, true)
        XCTAssertTrue(visibility.isShown(.cursor))
    }

    func testTheChoiceSurvivesRelaunch() throws {
        let defaults = try makeDefaults(#function)
        let visibility = ProviderVisibility(defaults: defaults)

        visibility.setShown(.codex, false)
        visibility.setShown(.openCode, false)

        XCTAssertEqual(ProviderVisibility(defaults: defaults).shown, [.claude, .cursor])
    }

    /// Hiding everything is allowed; it must persist as an empty set rather
    /// than being mistaken for a first run.
    func testHidingEverythingIsNotMistakenForAFirstRun() throws {
        let defaults = try makeDefaults(#function)
        let visibility = ProviderVisibility(defaults: defaults)

        for provider in Provider.allCases {
            visibility.setShown(provider, false)
        }

        XCTAssertTrue(ProviderVisibility(defaults: defaults).shown.isEmpty)
    }

    func testChangesAreReportedOnceAndOnlyWhenSomethingChanges() throws {
        let visibility = ProviderVisibility(defaults: try makeDefaults(#function))
        var reported: [Set<Provider>] = []
        visibility.onChange = { reported.append($0) }

        visibility.setShown(.cursor, false)
        visibility.setShown(.cursor, false)

        XCTAssertEqual(reported.count, 1, "a no-op toggle must not trigger a refresh")
        XCTAssertFalse(try XCTUnwrap(reported.first).contains(.cursor))
    }

    /// A provider added in a later version must be opted into rather than
    /// appearing unannounced in a panel someone has already tuned.
    func testAnUnknownStoredProviderIsIgnored() throws {
        let defaults = try makeDefaults(#function)
        defaults.set(["claude", "somethingNew"], forKey: "shownProviders")

        XCTAssertEqual(ProviderVisibility(defaults: defaults).shown, [.claude])
    }
}
