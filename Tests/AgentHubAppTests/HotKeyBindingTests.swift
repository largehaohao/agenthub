import XCTest
import Carbon.HIToolbox
@testable import AgentHubApp

final class HotKeyBindingTests: XCTestCase {
    func testDefaultIsCommandShiftT() {
        XCTAssertEqual(HotKeyBinding.default.displayName, "⇧⌘T")
        XCTAssertEqual(HotKeyBinding.default.keyCode, UInt32(kVK_ANSI_T))
        XCTAssertEqual(HotKeyBinding.default.modifiers, UInt32(cmdKey | shiftKey))
    }

    func testRecordsModifiersInTheOrderMacOSRendersThem() throws {
        let binding = try XCTUnwrap(
            HotKeyBinding.from(
                keyCode: UInt16(kVK_ANSI_J),
                flags: [.command, .control, .shift, .option],
                characters: "j"
            )
        )

        XCTAssertEqual(binding.displayName, "⌃⌥⇧⌘J")
        XCTAssertEqual(
            binding.modifiers,
            UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
    }

    /// A global hot key with no modifier would swallow that key in every app.
    func testBareKeyIsRejected() {
        XCTAssertNil(
            HotKeyBinding.from(keyCode: UInt16(kVK_ANSI_T), flags: [], characters: "t")
        )
    }

    /// Flags macOS sets for its own reasons must not become part of a binding.
    func testIrrelevantFlagsAreIgnored() throws {
        let binding = try XCTUnwrap(
            HotKeyBinding.from(
                keyCode: UInt16(kVK_ANSI_T),
                flags: [.command, .capsLock, .numericPad, .function],
                characters: "t"
            )
        )

        XCTAssertEqual(binding.displayName, "⌘T")
        XCTAssertEqual(binding.modifiers, UInt32(cmdKey))
    }

    /// Keys with no printable character cannot be named from the event's text.
    func testNamedKeysGetTheirSymbol() throws {
        let space = try XCTUnwrap(
            HotKeyBinding.from(keyCode: UInt16(kVK_Space), flags: [.option], characters: " ")
        )
        XCTAssertEqual(space.displayName, "⌥Space")

        let arrow = try XCTUnwrap(
            HotKeyBinding.from(keyCode: UInt16(kVK_UpArrow), flags: [.command], characters: nil)
        )
        XCTAssertEqual(arrow.displayName, "⌘↑")
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let binding = try XCTUnwrap(
            HotKeyBinding.from(keyCode: 40, flags: [.command, .option], characters: "k")
        )

        HotKeyBinding.save(binding, to: defaults)

        XCTAssertEqual(HotKeyBinding.load(from: defaults), binding)
    }

    func testUnsetDefaultsFallBackToTheDefaultBinding() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(HotKeyBinding.load(from: defaults), .default)
    }
}
