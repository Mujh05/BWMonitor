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

    @Test func fileCommandsPreserveSpacesAndRequireDestinations() throws {
        #expect(try BWMonitorCLIParser.parse(["files", "VPS", "--path", "/a folder"]) == .files(selector: "VPS", path: "/a folder"))
        #expect(try BWMonitorCLIParser.parse(["upload", "VPS", "/local file.txt", "--to", "/remote folder"]) == .upload(selector: "VPS", local: "/local file.txt", directory: "/remote folder"))
        #expect(try BWMonitorCLIParser.parse(["download", "VPS", "/remote file.txt", "--to", "/local file.txt"]) == .download(selector: "VPS", remote: "/remote file.txt", local: "/local file.txt"))
        #expect(throws: BWMonitorCLIParseError.self) { try BWMonitorCLIParser.parse(["upload", "VPS", "file"]) }
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
