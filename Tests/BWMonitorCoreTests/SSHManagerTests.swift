import XCTest
@testable import BWMonitorCore

final class SSHManagerTests: XCTestCase {
    func testKnownHostsPathIsQuotedForOpenSSHConfigParsing() {
        XCTAssertEqual(
            SSHManager.quoted("/tmp/Application Support/BWMonitor/KnownHosts/server.known_hosts"),
            "\"/tmp/Application Support/BWMonitor/KnownHosts/server.known_hosts\""
        )
    }

    func testHostIdentityParsingIgnoresKeyOrderAndComments() {
        let output = """
        # 104.194.82.27:22 SSH-2.0-OpenSSH
        104.194.82.27 ssh-rsa cnNh
        104.194.82.27 ecdsa-sha2-nistp256 ZWNkc2E=
        104.194.82.27 ssh-ed25519 ZWQyNTUxOQ==
        """

        let identities = KnownHosts.parse(output)

        XCTAssertEqual(identities.map(\.type), ["ssh-rsa", "ecdsa-sha2-nistp256", "ssh-ed25519"])
    }

    func testAnyMatchingSavedHostKeyIsRecognized() {
        let saved = KnownHosts.parse("""
            104.194.82.27 ssh-ed25519 ZWQyNTUxOQ==
            104.194.82.27 ecdsa-sha2-nistp256 ZWNkc2E=
            104.194.82.27 ssh-rsa cnNh
            """)
        let received = KnownHosts.parse("""
            104.194.82.27 ssh-rsa cnNh
            104.194.82.27 ecdsa-sha2-nistp256 ZWNkc2E=
            104.194.82.27 ssh-ed25519 ZWQyNTUxOQ==
            """)

        XCTAssertTrue(KnownHosts.matches(saved: saved, received: received))
    }
}
