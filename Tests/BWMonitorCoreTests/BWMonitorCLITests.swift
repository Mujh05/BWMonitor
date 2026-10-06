import Testing
@testable import BWMonitorCore

@Suite("BWMonitor CLI")
struct BWMonitorCLITests {
    @Test func parsesDataCommands() throws {
        #expect(try BWMonitorCLIParser.parse(["servers"]) == .servers)
        #expect(try BWMonitorCLIParser.parse(["list"]) == .servers)
        #expect(try BWMonitorCLIParser.parse(["status"]) == .status(selector: nil))
        #expect(try BWMonitorCLIParser.parse(["status", "Seoul VPS"]) == .status(selector: "Seoul VPS"))
        #expect(try BWMonitorCLIParser.parse(["traffic", "server-id"]) == .traffic(selector: "server-id"))
    }

    @Test func parsesRemoteCommandsWithoutFlatteningArguments() throws {
        #expect(
            try BWMonitorCLIParser.parse(["exec", "Seoul VPS", "--", "uname", "-a"])
                == .execute(selector: "Seoul VPS", command: ["uname", "-a"])
        )
        #expect(try BWMonitorCLIParser.parse(["shell", "Seoul VPS"]) == .shell(selector: "Seoul VPS"))
        #expect(try BWMonitorCLIParser.parse(["ssh", "Seoul VPS"]) == .shell(selector: "Seoul VPS"))
    }

    @Test func rejectsIncompleteOrAmbiguousSyntax() {
        #expect(throws: BWMonitorCLIParseError.missingServer) {
            try BWMonitorCLIParser.parse(["exec"])
        }
        #expect(throws: BWMonitorCLIParseError.missingRemoteCommand) {
            try BWMonitorCLIParser.parse(["exec", "server", "--"])
        }
        #expect(throws: BWMonitorCLIParseError.unexpectedArguments("extra")) {
            try BWMonitorCLIParser.parse(["servers", "extra"])
        }
        #expect(throws: BWMonitorCLIParseError.unknownCommand("unknown")) {
            try BWMonitorCLIParser.parse(["unknown"])
        }
    }
}
