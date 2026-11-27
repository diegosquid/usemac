import Darwin
import Foundation
import XCTest
@testable import UseMacEngine

final class AgentClientConfiguratorTests: XCTestCase {
    private let cliPath = "/Applications/UseMac.app/Contents/Helpers/usemac"
    private let socketPath = "/tmp/usemac-test.sock"
    private let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)

    func testDetectsAllFiveClientsWithoutWriting() throws {
        try withFixture { fixture in
            XCTAssertEqual(inspect(fixture).map(\.state), Array(repeating: .notInstalled, count: 5))
            try fixture.installAll()
            let statuses = inspect(fixture)
            XCTAssertEqual(statuses.map(\.client), AgentClientID.allCases)
            XCTAssertTrue(statuses.allSatisfy { $0.isInstalled && $0.state == .notConfigured })
            XCTAssertEqual(statuses.map(\.configPath), AgentClientID.allCases.map {
                fixture.home.appendingPathComponent($0.configRelativePath)
            })
            XCTAssertNil(statuses.first(where: { $0.client == .claudeDesktop })?.skillPath)
            XCTAssertFalse(fixture.exists(".agents"))
            XCTAssertTrue(statuses.allSatisfy { !FileManager.default.fileExists(atPath: $0.configPath.path) })
        }
    }

    func testDetectsConfigMarkersAndRequiresExecutableClaudeBinary() throws {
        try withFixture { fixture in
            try fixture.mkdir(".local/bin/claude")
            XCTAssertEqual(inspect(fixture, client: .claudeCode).state, .notInstalled)
            try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".local/bin/claude"))
            try fixture.write("", to: ".local/bin/claude")
            XCTAssertEqual(inspect(fixture, client: .claudeCode).state, .notInstalled)
            try fixture.write("{}", to: ".claude.json")
            try fixture.mkdir("Library/Application Support/Claude")
            try fixture.mkdir(".cursor")
            try fixture.mkdir(".codex")
            try fixture.mkdir(".gemini/antigravity")
            XCTAssertEqual(inspect(fixture).map(\.state), Array(repeating: .notConfigured, count: 5))
        }
    }

    func testCreatesConfigurationAndStampedSkillsForAllDetectedClients() throws {
        try withFixture { fixture in
            try fixture.installAll()
            let results = fixture.configurator.configureAllDetected(
                cliPath: cliPath, socketPath: socketPath, agentDocsDir: fixture.docs, confirmedBy: click
            )

            XCTAssertEqual(results.map(\.client), AgentClientID.allCases)
            for result in results { XCTAssertEqual(try result.result.get().state, .configured) }
            for client in AgentClientID.allCases where client != .codex {
                try assertJSONServer(fixture, client: client)
                XCTAssertFalse(fixture.exists(client.configRelativePath + ".usemac.bak"))
            }
            XCTAssertEqual(
                try fixture.read(".codex/config.toml"),
                "[mcp_servers.usemac]\ncommand = \"\(cliPath)\"\nargs = [\"mcp\"]\n"
            )
            for root in [
                ".agents/skills", ".claude/skills", ".cursor/skills", ".codex/skills", ".gemini/antigravity/skills"
            ] {
                let skill = try fixture.read(root + "/usemac/SKILL.md")
                let reference = try fixture.read(root + "/usemac/references/REFERENCE.md")
                XCTAssertEqual(skill, "---\nname: usemac\n---\nRun \(cliPath) on \(socketPath).\n")
                XCTAssertEqual(reference, "Reference for \(cliPath) and \(socketPath).\n")
            }
            XCTAssertFalse(fixture.exists("Library/Application Support/Claude/skills"))
            XCTAssertTrue(inspect(fixture).allSatisfy { $0.state == .configured })
        }
    }

    func testClaudeDesktopOnlyDoesNotInstallUniversalSkill() throws {
        try withFixture { fixture in
            try fixture.mkdir("Library/Application Support/Claude")
            try configure(.claudeDesktop, in: fixture)
            XCTAssertFalse(fixture.exists(".agents"))
            try assertJSONServer(fixture, client: .claudeDesktop)
        }
    }

    func testJSONMergesPreserveSettingsAndOtherServersAndOnlyBackUpOncePerChange() throws {
        try withFixture { fixture in
            let original = """
                {"mcpServers":{"anotherServer":{"command":"/bin/echo","args":["existing"]},"usemac":{"command":"/old","args":["mcp"]}},"ui":{"enabled":true},"count":7}
                """
            for client in AgentClientID.allCases where client != .codex {
                let path = client.configRelativePath
                try fixture.write(original, to: path)
                XCTAssertEqual(inspect(fixture, client: client).state, .needsUpdate)
                try configure(client, in: fixture)
                let updated = try fixture.read(path)
                let object = try assertJSONServer(fixture, client: client)
                XCTAssertEqual(object["count"] as? Int, 7)
                XCTAssertEqual(object["ui"] as? [String: Bool], ["enabled": true])
                let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
                XCTAssertEqual(servers["anotherServer"]?["command"] as? String, "/bin/echo")
                XCTAssertEqual(servers["anotherServer"]?["args"] as? [String], ["existing"])
                XCTAssertEqual(try fixture.read(path + ".usemac.bak"), original)

                try configure(client, in: fixture)
                XCTAssertEqual(try fixture.read(path), updated)
                XCTAssertEqual(try fixture.read(path + ".usemac.bak"), original)
            }
        }
    }

    func testAppendsCodexTableWithSeparatorWithoutRewritingOriginalBytes() throws {
        try withFixture { fixture in
            let original = "# A comment\r\n[projects.\"/tmp/example\"]\r\ntrust_level = 'trusted'\r\n"
            let path = AgentClientID.codex.configRelativePath
            try fixture.write(original, to: path)
            try configure(.codex, in: fixture)
            XCTAssertEqual(
                try fixture.read(path),
                original + "\r\n[mcp_servers.usemac]\r\ncommand = \"\(cliPath)\"\r\nargs = [\"mcp\"]\r\n"
            )
            XCTAssertEqual(try fixture.read(path + ".usemac.bak"), original)
        }
    }

    func testUpdatesOnlyCodexTableEvenWithHeadersInMultilineStrings() throws {
        try withFixture { fixture in
            let prefix = "# Before\r\ntext = '''\r\n[mcp_servers.usemac]\r\nNot a table\r\n'''\r\n"
            let header = "[mcp_servers . 'usemac'] # Keep the header comment\r\n"
            let previousSettings = "command = '/old/bin' # Keep this note\r\nargs = [\r\n 'mcp'\r\n]\r\n# Before the next table\r\n\r\n"
            let suffix = "[[another]] # Keep spacing\r\nweird  =  'text'\r\n[mcp_servers.other]\r\ncommand = '/another'"
            let original = prefix + header + previousSettings + suffix
            let path = AgentClientID.codex.configRelativePath
            try fixture.write(original, to: path)

            let escapedPath = "/Example \"with quotes\" and \\ backslash/UseMac\t"
            try configure(.codex, in: fixture, cli: escapedPath)
            let updated = try fixture.read(path)
            let expectedSettings = "command = \"/Example \\\"with quotes\\\" and \\\\ backslash/UseMac\\u0009\"\r\nargs = [\"mcp\"]\r\n"
            XCTAssertEqual(updated, prefix + header + expectedSettings + "# Keep this note\r\n# Before the next table\r\n\r\n" + suffix)
            XCTAssertEqual(try fixture.read(path + ".usemac.bak"), original)
            XCTAssertEqual(inspect(fixture, client: .codex, cli: escapedPath).state, .configured)

            try configure(.codex, in: fixture, cli: escapedPath)
            XCTAssertEqual(try fixture.read(path), updated)
            XCTAssertEqual(try fixture.read(path + ".usemac.bak"), original)
        }
    }

    func testRejectsMalformedJSONAndContinuesWithOtherDetectedClients() throws {
        try withFixture { fixture in
            let malformed = "{ \"mcpServers\": "
            let cursorPath = AgentClientID.cursor.configRelativePath
            let claudePath = AgentClientID.claudeCode.configRelativePath
            let desktopPath = AgentClientID.claudeDesktop.configRelativePath
            try fixture.write(malformed, to: cursorPath)
            try fixture.write("[]", to: claudePath)
            try fixture.write("{\"mcpServers\": false}", to: desktopPath)
            try fixture.mkdir(".gemini/antigravity")

            let results = fixture.configurator.configureAllDetected(
                cliPath: cliPath, socketPath: socketPath, agentDocsDir: fixture.docs, confirmedBy: click
            )
            XCTAssertEqual(results.count, 4)
            for entry in results {
                if entry.client == .antigravity {
                    XCTAssertEqual(try entry.result.get().state, .configured)
                } else {
                    XCTAssertThrowsError(try entry.result.get())
                }
            }
            XCTAssertTrue(inspect(fixture, client: .cursor).detail.contains("invalid JSON"))
            XCTAssertEqual(try fixture.read(cursorPath), malformed)
            XCTAssertEqual(try fixture.read(claudePath), "[]")
            XCTAssertEqual(try fixture.read(desktopPath), "{\"mcpServers\": false}")
            XCTAssertFalse(fixture.exists(cursorPath + ".usemac.bak"))
            XCTAssertFalse(fixture.exists(".cursor/skills"))
        }
    }

    func testRefusesMalformedOrConflictingCodexTableWithoutBackupOrSkillWrites() throws {
        let malformed = [
            Data([0xff]),
            Data("[mcp_servers.usemac]\ncommand = ".utf8),
            Data("[mcp_servers.usemac]\ncommand = /no-quotes\n[other]\nname = 'unchanged'".utf8),
            Data("[mcp_servers.usemac]\nargs = [\"mcp\"\n[other]\nname = 'unchanged'".utf8),
            Data("[mcp_servers.usemac]\ncommand = '/old'\ncommand = '/duplicate'\n".utf8),
            Data("[mcp_servers.usemac]\n[mcp_servers.'usemac']\n".utf8),
            Data("[mcp_servers]\nusemac.command = '/old'\n".utf8),
            Data("[mcp_servers.usemac\ncommand = '/old'\n".utf8),
            Data("entries = ['incomplete'\n".utf8)
        ]
        try withFixture { fixture in
            let path = AgentClientID.codex.configRelativePath
            for original in malformed {
                try fixture.write(original, to: path)
                XCTAssertThrowsError(try configure(.codex, in: fixture)) {
                    XCTAssertTrue($0.localizedDescription.contains("TOML"), $0.localizedDescription)
                }
                XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent(path)), original)
                XCTAssertFalse(fixture.exists(path + ".usemac.bak"))
                XCTAssertFalse(fixture.exists(".codex/skills"))
            }
        }
    }

    func testRefusesSymlinksAtConfigBackupAndEverySkillDestination() throws {
        let config = ".cursor/mcp.json"
        let paths = [
            config, ".cursor", config + ".usemac.bak", ".cursor/skills/usemac",
            ".cursor/skills/usemac/SKILL.md", ".cursor/skills/usemac/references",
            ".cursor/skills/usemac/references/REFERENCE.md", ".agents/skills", ".agents/skills/usemac"
        ]
        for path in paths {
            try withFixture { fixture in
                let protected = fixture.home.appendingPathComponent("protected")
                if path == ".cursor" {
                    try fixture.write("{}", to: "protected/mcp.json")
                } else {
                    try fixture.write("keep me", to: "protected")
                }
                let original = path == config || path == ".cursor" ? nil : "{}"
                if let original { try fixture.write(original, to: config) }
                try fixture.symlink(path, to: protected)

                XCTAssertThrowsError(try configure(.cursor, in: fixture), path) {
                    XCTAssertTrue($0.localizedDescription.contains("symbolic link"), $0.localizedDescription)
                }
                if let original { XCTAssertEqual(try fixture.read(config), original) }
                if path == ".cursor" {
                    XCTAssertEqual(try fixture.read("protected/mcp.json"), "{}")
                } else {
                    XCTAssertEqual(try fixture.read("protected"), "keep me")
                }
                XCTAssertFalse(fixture.exists(".agents/skills/usemac/references"))
            }
        }
    }

    func testRefusesAnotherSkillEvenWhenItsBodyContainsNameUsemac() throws {
        try withFixture { fixture in
            let path = ".claude/skills/usemac/SKILL.md"
            let original = "---\nname: another-skill\n---\nname: usemac\n"
            try fixture.write(original, to: path)

            XCTAssertThrowsError(try configure(.claudeCode, in: fixture)) {
                XCTAssertTrue($0.localizedDescription.contains("frontmatter"))
            }
            XCTAssertEqual(try fixture.read(path), original)
            XCTAssertFalse(fixture.exists(".claude.json"))
            XCTAssertFalse(fixture.exists(".agents"))
        }
    }

    func testNeedsUpdateForNewCLIPathNewSocketOrMissingReference() throws {
        try withFixture { fixture in
            try fixture.installAll()
            try configure(.codex, in: fixture)
            XCTAssertEqual(inspect(fixture, client: .codex).state, .configured)
            XCTAssertEqual(inspect(fixture, client: .codex, cli: "/new/path/usemac").state, .needsUpdate)
            XCTAssertEqual(inspect(fixture, client: .codex, socket: "/new/usemac.sock").state, .needsUpdate)
            try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".codex/skills/usemac/references/REFERENCE.md"))
            XCTAssertEqual(inspect(fixture, client: .codex).state, .needsUpdate)
            try configure(.codex, in: fixture)
            XCTAssertEqual(inspect(fixture, client: .codex).state, .configured)
            XCTAssertFalse(fixture.exists(".codex/config.toml.usemac.bak"))
        }
    }

    private struct Fixture {
        let root: URL

        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var apps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
        var docs: URL { root.appendingPathComponent("agent-docs", isDirectory: true) }

        var configurator: AgentClientConfigurator {
            AgentClientConfigurator(environment: .init(
                homeDirectory: home,
                applicationsDirectory: apps,
                claudeBinaryCandidates: [home.appendingPathComponent(".local/bin/claude")]
            ))
        }

        func installAll() throws {
            try write("#!/bin/sh\n", to: ".local/bin/claude")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent(".local/bin/claude").path)
            try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"), withIntermediateDirectories: true)
            try mkdir("Applications/Cursor.app")
            try FileManager.default.createDirectory(at: apps.appendingPathComponent("Codex.app"), withIntermediateDirectories: true)
            try mkdir("Applications/Antigravity.app")
        }

        func mkdir(_ path: String) throws {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }

        func write(_ string: String, to path: String) throws { try write(Data(string.utf8), to: path) }

        func write(_ data: Data, to path: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

        func symlink(_ path: String, to target: URL) throws {
            let link = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Darwin.symlink(target.path, link.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private func withFixture(_ test: (Fixture) throws -> Void) throws {
        let fixture = Fixture(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try fixture.mkdir("")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let skill = fixture.docs.appendingPathComponent("skills/usemac")
        let reference = skill.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try "---\nname: usemac\n---\nRun {{USEMAC_BIN}} on {{USEMAC_SOCKET}}.\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "Reference for {{USEMAC_BIN}} and {{USEMAC_SOCKET}}.\n"
            .write(to: reference.appendingPathComponent("REFERENCE.md"), atomically: true, encoding: .utf8)
        try test(fixture)
    }

    private func inspect(_ fixture: Fixture, cli: String? = nil, socket: String? = nil) -> [AgentClientStatus] {
        fixture.configurator.inspectAll(cliPath: cli ?? cliPath, socketPath: socket ?? socketPath, agentDocsDir: fixture.docs)
    }

    private func inspect(_ fixture: Fixture, client: AgentClientID, cli: String? = nil, socket: String? = nil) -> AgentClientStatus {
        inspect(fixture, cli: cli, socket: socket).first { $0.client == client }!
    }

    private func configure(_ client: AgentClientID, in fixture: Fixture, cli: String? = nil) throws {
        try fixture.configurator.configure(
            client: client, cliPath: cli ?? cliPath, socketPath: socketPath, agentDocsDir: fixture.docs, confirmedBy: click
        )
    }

    @discardableResult
    private func assertJSONServer(_ fixture: Fixture, client: AgentClientID) throws -> [String: Any] {
        let url = fixture.home.appendingPathComponent(client.configRelativePath)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["usemac"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, cliPath, client.rawValue)
        XCTAssertEqual(server["args"] as? [String], ["mcp"], client.rawValue)
        return object
    }
}
