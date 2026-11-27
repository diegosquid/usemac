import Foundation
import Darwin
import MachO

extension UseMacCLI {
    private struct InstallSkillTargetResult: Encodable {
        let path: String
        let status: String
    }

    private struct InstallSkillOutput: Encodable {
        let ok: Bool
        let binary: String
        let targets: [InstallSkillTargetResult]
    }

    static func handleInstallSkill(args: [String], options: GlobalOptions) throws -> Int32 {
        var workspaceOnly = false
        var customDir: String?
        var force = false
        var dryRun = false
        var idx = 0

        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--workspace", "-w":
                workspaceOnly = true
                idx += 1
            case "--dir", "-d":
                guard idx + 1 < args.count else {
                    throw CLIError.usage("Missing path after \(arg).")
                }
                customDir = (args[idx + 1] as NSString).expandingTildeInPath
                idx += 2
            case "--force":
                force = true
                idx += 1
            case "--dry-run":
                dryRun = true
                idx += 1
            default:
                if arg.hasPrefix("--dir=") {
                    let raw = String(arg.dropFirst("--dir=".count))
                    guard !raw.isEmpty else {
                        throw CLIError.usage("Missing path after --dir=.")
                    }
                    customDir = (raw as NSString).expandingTildeInPath
                    idx += 1
                } else {
                    throw CLIError.usage("Unknown option for install-skill: '\(arg)'.")
                }
            }
        }

        let execURL = resolveExecutableURL()
        let resolvedBin = FileManager.default.isExecutableFile(atPath: execURL.path) ? execURL.path : "usemac"
        let rawSkill = loadSkillMarkdownTemplate(execURL: execURL)
        let stampedSkill = rawSkill
            .replacingOccurrences(of: "{{USEMAC_BIN}}", with: resolvedBin)
            .replacingOccurrences(of: "{{USEMAC_SOCKET}}", with: options.socketPath)
        let stampedReference = loadSkillReferenceTemplate(execURL: execURL)?
            .replacingOccurrences(of: "{{USEMAC_BIN}}", with: resolvedBin)
            .replacingOccurrences(of: "{{USEMAC_SOCKET}}", with: options.socketPath)

        var targetSkillRoots: [URL] = []
        let fm = FileManager.default

        if let customDir {
            targetSkillRoots.append(URL(fileURLWithPath: customDir, isDirectory: true))
        } else if workspaceOnly {
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            targetSkillRoots.append(cwd.appendingPathComponent(".agents/skills", isDirectory: true))
        } else {
            let home = fm.homeDirectoryForCurrentUser
            // Always install to universal ~/.agents/skills
            targetSkillRoots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))

            // Also install to detected agent homes on this Mac
            let candidateHomes: [(check: String, skillsRel: String)] = [
                (".codex", ".codex/skills"),
                (".claude", ".claude/skills"),
                (".cursor", ".cursor/skills"),
                (".gemini/antigravity", ".gemini/antigravity/skills")
            ]
            for candidate in candidateHomes {
                let checkURL = home.appendingPathComponent(candidate.check, isDirectory: true)
                if fm.fileExists(atPath: checkURL.path) {
                    targetSkillRoots.append(home.appendingPathComponent(candidate.skillsRel, isDirectory: true))
                }
            }
        }

        var results: [InstallSkillTargetResult] = []
        for root in targetSkillRoots {
            let destDir = root.appendingPathComponent("usemac", isDirectory: true)
            let destFile = destDir.appendingPathComponent("SKILL.md", isDirectory: false)
            let status: String

            if isSymbolicLink(atPath: destDir.path) || isSymbolicLink(atPath: destFile.path) {
                status = "skipped (symlink)"
            } else if !fm.fileExists(atPath: destFile.path) {
                status = "installed"
                if !dryRun {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                }
            } else {
                let existing = try? String(contentsOf: destFile, encoding: .utf8)
                if existing == stampedSkill {
                    status = "up to date"
                } else if hasUsemacSkillHeader(existing) {
                    status = "updated"
                    if !dryRun {
                        try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                    }
                } else if force {
                    status = "replaced"
                    if !dryRun {
                        try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                    }
                } else {
                    status = "skipped (not a UseMac skill; use --force)"
                }
            }

            let reportedStatus = dryRun ? "would be \(status)" : status
            results.append(InstallSkillTargetResult(path: destFile.path, status: reportedStatus))

            // Keep references/REFERENCE.md in sync alongside SKILL.md whenever the skill itself was installed/updated/up-to-date.
            if let stampedReference,
               status == "installed" || status == "updated" || status == "replaced" || status == "up to date" {
                let refDir = destDir.appendingPathComponent("references", isDirectory: true)
                let refFile = refDir.appendingPathComponent("REFERENCE.md", isDirectory: false)
                let refStatus: String
                if isSymbolicLink(atPath: refDir.path) || isSymbolicLink(atPath: refFile.path) {
                    refStatus = "skipped (symlink)"
                } else if !fm.fileExists(atPath: refFile.path) {
                    refStatus = "installed"
                    if !dryRun {
                        try fm.createDirectory(at: refDir, withIntermediateDirectories: true)
                        try stampedReference.write(to: refFile, atomically: true, encoding: .utf8)
                    }
                } else {
                    let existingRef = try? String(contentsOf: refFile, encoding: .utf8)
                    if existingRef == stampedReference {
                        refStatus = "up to date"
                    } else {
                        refStatus = "updated"
                        if !dryRun {
                            try stampedReference.write(to: refFile, atomically: true, encoding: .utf8)
                        }
                    }
                }
                results.append(InstallSkillTargetResult(
                    path: refFile.path,
                    status: dryRun ? "would be \(refStatus)" : refStatus
                ))
            }

            let legacyDir = root.appendingPathComponent("macuse", isDirectory: true) // Legacy skill folder from the old product name.
            let legacyFile = legacyDir.appendingPathComponent("SKILL.md", isDirectory: false)
            if !isSymbolicLink(atPath: legacyDir.path),
               !isSymbolicLink(atPath: legacyFile.path),
               fm.fileExists(atPath: legacyFile.path),
               let legacyContent = try? String(contentsOf: legacyFile, encoding: .utf8),
               hasLegacySkillHeader(legacyContent) {
                results.append(InstallSkillTargetResult(
                    path: legacyFile.path,
                    status: "legacy skill found, remove it manually"
                ))
            }
        }

        if options.json {
            printEncodableJSON(InstallSkillOutput(ok: true, binary: resolvedBin, targets: results))
        } else {
            for target in results {
                print("\(target.status): \(target.path)")
            }
        }
        return 0
    }

    private static func resolveExecutableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer)
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            }
        }
        if let bundleExec = Bundle.main.executableURL {
            return bundleExec.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        var st = stat()
        guard lstat(trimmed, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func hasUsemacSkillHeader(_ content: String?) -> Bool {
        guard let content else { return false }
        let lines = content.components(separatedBy: .newlines).prefix(10)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "name: usemac" }
    }

    private static func hasLegacySkillHeader(_ content: String?) -> Bool {
        guard let content else { return false }
        let lines = content.components(separatedBy: .newlines).prefix(10)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "name: macuse" } // Legacy skill folder from the old product name.
    }

    private static func loadSkillReferenceTemplate(execURL: URL) -> String? {
        // 1. Inside UseMac.app/Contents/Helpers/usemac -> ../Resources/agent/skills/usemac/references/REFERENCE.md
        let bundledRef = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/agent/skills/usemac/references/REFERENCE.md")
        if let content = try? String(contentsOf: bundledRef, encoding: .utf8), !content.isEmpty {
            return content
        }
        // 2. Repo-relative fallback during local CLI development
        let cwdRef = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".agents/skills/usemac/references/REFERENCE.md")
        if let content = try? String(contentsOf: cwdRef, encoding: .utf8), !content.isEmpty {
            return content
        }
        return nil
    }

    private static func loadSkillMarkdownTemplate(execURL: URL) -> String {
        // 1. Inside UseMac.app/Contents/Helpers/usemac -> ../Resources/agent/skills/usemac/SKILL.md
        let bundledSkill = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/agent/skills/usemac/SKILL.md")
        if let content = try? String(contentsOf: bundledSkill, encoding: .utf8), !content.isEmpty {
            return content
        }

        // 2. Embedded self-contained fallback
        return """
        ---
        name: usemac
        description: Control native macOS desktop applications in the background with Accessibility inspection and zero-focus UI actions via UseMac.
        ---

        # UseMac — Native macOS Background Computer Control

        Always act in the background (`preferBackground: true` on steps, `open -g -a "<App>"`) so you never steal window focus from the user.

        - Check status: `"{{USEMAC_BIN}}" status`
        - Observe app: `"{{USEMAC_BIN}}" observe --app "<AppName>"`
        - Batch actions: `"{{USEMAC_BIN}}" act '{"app":"<AppName>","returnObservation":true,"returnDiffOnly":true,"steps":[{"action":"click","elementId":"@e1","preferBackground":true}]}'`
        """
    }
}
