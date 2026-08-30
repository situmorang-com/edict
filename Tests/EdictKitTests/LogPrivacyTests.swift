import Foundation
import Testing
@testable import EdictKit

/// The one class of string in this app that must not print into the unified log.
///
/// Before this, `Sources/` held 222 `privacy: .public` interpolations and not a single `.private` — so
/// there was no discipline at all for the one field that needs it. Twenty-three of those sites
/// interpolated a user-chosen audio filename, several at `.error` or `.notice`, which persist to the
/// on-disk log store and are collected verbatim by any sysdiagnose. "HR grievance call 2026-08-24.m4a"
/// is informative in exactly the way this codebase treats as sensitive in the other direction:
/// `TranscriptSource.imported(filename:)` is documented as basename-only "because a home directory is
/// nobody's business", and then the same name went out `.public` twenty-three times.
///
/// This suite reads the source. That is unusual and it is deliberate: the rule is about how a call is
/// WRITTEN, there is no runtime observable for it, and the finding that opened it said outright that
/// the suite could not enforce it with a source grep. It can — this is the grep, with a failure
/// message. A new `.public` filename log now fails a test instead of shipping.
///
/// What it deliberately does NOT cover: `AppPaths`' directory logs, which stay `.public` because they
/// name Edict's own support directory and RECON amendment 39's whole point is that the override path
/// must be loud about where it is writing.
@Suite("Log privacy")
struct LogPrivacyTests {

    /// The expressions that carry a user-chosen filename in the three files that log one.
    private static let filenameExpressions = [
        "self.items[index].filename",
        "source.filename",
        "result.info.filename",
        "self.filename",
        "filename",
    ]

    private static let filesThatLogFilenames = [
        "Sources/EdictKit/Engine/ImportQueue.swift",
        "Sources/EdictKit/Engine/AudioFileImporter.swift",
        "Sources/EdictKit/App/DictationController.swift",
    ]

    /// Walk up from this file to the package root, so the suite does not depend on the working
    /// directory a runner happens to use.
    private static var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
        }
        return dir
    }

    @Test("No user-chosen filename is interpolated into a log as .public")
    func filenamesAreNeverPublic() throws {
        var offenders: [String] = []

        for relative in Self.filesThatLogFilenames {
            let url = Self.packageRoot.appendingPathComponent(relative)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "could not read \(relative) — if the file moved, this suite needs updating, not deleting"
            )

            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("privacy: .public") else { continue }
                for expression in Self.filenameExpressions
                where line.contains("\\(\(expression), privacy: .public)") {
                    offenders.append("\(relative):\(index + 1) — \\(\(expression), privacy: .public)")
                }
            }
        }

        #expect(offenders.isEmpty, """
            \(offenders.count) log site(s) print a user-chosen audio filename into the unified log:

            \(offenders.joined(separator: "\n"))

            Use `privacy: .private(mask: .hash)`. The hash keeps every line of one import correlatable,
            which is what a support log actually needs, without writing the name of the recording into
            a log that persists on disk and is collected verbatim by any sysdiagnose. If the format is
            what you need, `audioFileKind(of:)` gives you the extension alone and that can stay public.
            """)
    }

    @Test("The filename hashes really are in place, so the suite above is not passing on an empty set")
    func theHashesArePresent() throws {
        // The counterpart the check above cannot make: `offenders.isEmpty` also passes if the files
        // stopped logging filenames altogether, or if this suite's expression list went stale and
        // matches nothing. Pinning the count means a rewrite that drops the masking has to come here
        // and say so.
        var hashed = 0
        for relative in Self.filesThatLogFilenames {
            let url = Self.packageRoot.appendingPathComponent(relative)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8))
            hashed += source.components(separatedBy: "privacy: .private(mask: .hash)").count - 1
        }

        #expect(hashed >= 23, """
            only \(hashed) hashed filename interpolations remain, of the 23 this change made. If a log
            line was legitimately removed, lower this number and say which; if masking was reverted,
            that is the bug.
            """)
    }
}
