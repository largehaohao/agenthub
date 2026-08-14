import XCTest
@testable import AgentHubQuota

final class LoginShellEnvironmentTests: XCTestCase {
    private func captured(_ body: String) -> Data {
        Data((LoginShellEnvironment.sentinel + body).utf8)
    }

    func testParsesNulSeparatedVariables() {
        let values = LoginShellEnvironment.parse(
            captured("PATH=/usr/bin\0HTTPS_PROXY=http://127.0.0.1:1087\0HOME=/Users/example\0")
        )

        XCTAssertEqual(values["PATH"], "/usr/bin")
        XCTAssertEqual(values["HTTPS_PROXY"], "http://127.0.0.1:1087")
        XCTAssertEqual(values["HOME"], "/Users/example")
    }

    /// An interactive rc file may print a banner or a version notice before the
    /// environment; none of it is a variable.
    func testChatterBeforeTheSentinelIsDiscarded() {
        let values = LoginShellEnvironment.parse(
            Data("nvm: version 20\nsome banner\n".utf8) + captured("PATH=/usr/bin\0")
        )

        XCTAssertEqual(values, ["PATH": "/usr/bin"])
    }

    /// Real configs export values containing newlines. Splitting on newlines
    /// would cut one variable into several bogus ones.
    func testValuesMayContainNewlines() {
        let values = LoginShellEnvironment.parse(
            captured("LS_COLORS=a\nb\nc\0PATH=/usr/bin\0")
        )

        XCTAssertEqual(values["LS_COLORS"], "a\nb\nc")
        XCTAssertEqual(values["PATH"], "/usr/bin")
    }

    func testValuesMayContainEqualsSigns() {
        let values = LoginShellEnvironment.parse(captured("OPTS=a=1,b=2\0"))

        XCTAssertEqual(values["OPTS"], "a=1,b=2")
    }

    /// An exported bash function is not a variable and must not be passed on as
    /// one.
    func testExportedShellFunctionsAreDropped() {
        let values = LoginShellEnvironment.parse(
            captured("BASH_FUNC_foo%%=() { echo hi\n}\0PATH=/usr/bin\0")
        )

        XCTAssertNil(values["BASH_FUNC_foo%%"])
        XCTAssertEqual(values["PATH"], "/usr/bin")
    }

    func testGarbageYieldsNothingRatherThanThrowing() {
        XCTAssertEqual(LoginShellEnvironment.parse(Data([0xFF, 0xFE, 0xFD])), [:])
        XCTAssertEqual(LoginShellEnvironment.parse(Data()), [:])
    }

    /// Starting a login shell is slow, so it must happen once, not per refresh.
    func testTheShellIsAskedOnlyOnce() async {
        let counter = Counter()
        let environment = LoginShellEnvironment(capture: {
            await counter.increment()
            return Data((LoginShellEnvironment.sentinel + "PATH=/usr/bin\0").utf8)
        })

        _ = await environment.values()
        _ = await environment.values()
        _ = await environment.values()

        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    /// A user with no shell, or a shell that fails, still gets a working app —
    /// the inherited environment is simply left as it is.
    func testAFailedCaptureYieldsNoOverrides() async {
        let environment = LoginShellEnvironment(capture: { nil })

        let values = await environment.values()

        XCTAssertEqual(values, [:])
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}
