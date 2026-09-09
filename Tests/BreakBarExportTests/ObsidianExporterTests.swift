import BreakBarExport
import BreakBarPersistence
import Foundation
import XCTest

final class ObsidianExporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BreakBarExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRenderSectionIncludesSummaryAndTimeline() {
        let history = sampleHistory()

        let rendered = ObsidianExporter().renderSection(
            history: history,
            at: date("2026-09-08T17:36:00Z"),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        ).replacingOccurrences(of: "\u{202F}", with: " ")

        XCTAssertTrue(rendered.hasPrefix("<!-- breakbar:start -->\n## Work"))
        XCTAssertTrue(rendered.contains("**Clocked in:** 8:47 AM"))
        XCTAssertTrue(rendered.contains("**Clocked out:** 10:47 AM"))
        XCTAssertTrue(rendered.contains("**Working:** 1h 39m · **Focus:** 55m · **Meetings:** 44m"))
        XCTAssertTrue(rendered.contains("**Breaks:** 16m · **Lunch:** 0m · **Travel:** 0m · **Away:** 0m"))
        XCTAssertTrue(rendered.contains("| Focus | 8:47 AM | 9:42 AM | 55m | |"))
        XCTAssertTrue(rendered.contains("| Meeting | 10:03 AM | 10:47 AM | 44m | |"))
        XCTAssertTrue(rendered.hasSuffix("<!-- breakbar:end -->"))
    }

    func testExportCreatesNoteAndSkipsIdenticalRewrite() throws {
        let exporter = ObsidianExporter()
        let history = sampleHistory()
        let now = date("2026-09-08T17:36:00Z")

        let first = try exporter.export(
            history: history,
            at: now,
            to: temporaryDirectory,
            filenameFormat: "yyyy-MM-dd",
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let firstContents = try String(contentsOf: first.noteURL, encoding: .utf8)
        let second = try exporter.export(
            history: history,
            at: now,
            to: temporaryDirectory,
            filenameFormat: "yyyy-MM-dd",
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(first.noteURL.lastPathComponent, "2026-09-08.md")
        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try String(contentsOf: second.noteURL, encoding: .utf8), firstContents)
        XCTAssertEqual(firstContents.components(separatedBy: ObsidianExporter.startMarker).count - 1, 1)
        XCTAssertEqual(firstContents.components(separatedBy: ObsidianExporter.endMarker).count - 1, 1)
    }

    func testExportReplacesOnlyExistingBreakBarSection() throws {
        let exporter = ObsidianExporter()
        let noteURL = temporaryDirectory.appendingPathComponent("2026-09-08.md")
        try """
        # Tuesday

        Personal text before.

        <!-- breakbar:start -->
        stale export
        <!-- breakbar:end -->

        Personal text after.
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        let result = try exporter.export(
            history: sampleHistory(),
            at: date("2026-09-08T17:36:00Z"),
            to: temporaryDirectory,
            filenameFormat: "yyyy-MM-dd",
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let contents = try String(contentsOf: result.noteURL, encoding: .utf8)

        XCTAssertTrue(contents.hasPrefix("# Tuesday\n\nPersonal text before."))
        XCTAssertTrue(contents.hasSuffix("Personal text after."))
        XCTAssertFalse(contents.contains("stale export"))
        XCTAssertTrue(contents.contains("**Working:**"))
        XCTAssertEqual(contents.components(separatedBy: ObsidianExporter.startMarker).count - 1, 1)
        XCTAssertEqual(contents.components(separatedBy: ObsidianExporter.endMarker).count - 1, 1)
    }

    func testExportAppendsToAnExistingNoteWithoutMarkers() throws {
        let noteURL = temporaryDirectory.appendingPathComponent("2026-09-08.md")
        try "# Tuesday\n\nPersonal text.\n".write(
            to: noteURL,
            atomically: true,
            encoding: .utf8
        )

        _ = try ObsidianExporter().export(
            history: sampleHistory(),
            at: date("2026-09-08T17:36:00Z"),
            to: temporaryDirectory,
            filenameFormat: "yyyy-MM-dd",
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let contents = try String(contentsOf: noteURL, encoding: .utf8)

        XCTAssertTrue(contents.hasPrefix("# Tuesday\n\nPersonal text.\n\n<!-- breakbar:start -->"))
        XCTAssertTrue(contents.hasSuffix("<!-- breakbar:end -->\n"))
    }

    func testMarkerConflictsAreRejected() {
        let conflicts = [
            "<!-- breakbar:start -->\nmissing end",
            "<!-- breakbar:end -->\nmissing start",
            "<!-- breakbar:end -->\n<!-- breakbar:start -->",
            "<!-- breakbar:start -->\na\n<!-- breakbar:start -->\nb\n<!-- breakbar:end -->",
        ]

        for conflict in conflicts {
            XCTAssertThrowsError(
                try ObsidianExporter.updatingNote(conflict, with: "replacement")
            ) { error in
                XCTAssertEqual(error as? ObsidianExportError, .markerConflict)
            }
        }
    }

    func testCrossMidnightIntervalsAreClippedToTheDailyNote() {
        let dayStart = date("2026-09-08T00:00:00Z")
        let history = DailyHistory(
            day: DateInterval(start: dayStart, duration: 24 * 60 * 60),
            sessions: [
                WorkSessionHistory(
                    id: "session",
                    startedAt: date("2026-09-07T23:50:00Z"),
                    endedAt: date("2026-09-08T00:20:00Z"),
                    correctedFromStartedAt: nil,
                    correctedFromEndedAt: nil,
                    updatedAt: date("2026-09-08T00:20:00Z")
                ),
            ],
            intervals: [
                ActivityHistoryInterval(
                    id: "focus",
                    sessionID: "session",
                    kind: .focus,
                    startedAt: date("2026-09-07T23:50:00Z"),
                    endedAt: date("2026-09-08T00:20:00Z"),
                    source: "state_machine",
                    correctedFromKind: nil,
                    updatedAt: date("2026-09-08T00:20:00Z")
                ),
            ]
        )

        let rendered = ObsidianExporter().renderSection(
            history: history,
            at: date("2026-09-08T01:00:00Z"),
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        ).replacingOccurrences(of: "\u{202F}", with: " ")

        XCTAssertTrue(rendered.contains("**Working:** 20m"))
        XCTAssertTrue(rendered.contains("| Focus | 12:00 AM | 12:20 AM | 20m | |"))
    }

    func testInvalidFilenameAndUnavailableFolderAreRejected() {
        let exporter = ObsidianExporter()
        XCTAssertThrowsError(
            try exporter.noteURL(
                for: date("2026-09-08T00:00:00Z"),
                in: temporaryDirectory,
                filenameFormat: "yyyy/'..'/MM",
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? ObsidianExportError, .invalidFilenameFormat)
        }

        let missingFolder = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(
            try exporter.export(
                history: sampleHistory(),
                at: date("2026-09-08T17:36:00Z"),
                to: missingFolder,
                filenameFormat: "yyyy-MM-dd",
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? ObsidianExportError, .folderUnavailable)
        }
    }

    func testNestedDatePathIsCreatedInsideSelectedFolder() throws {
        let result = try ObsidianExporter().export(
            history: sampleHistory(),
            at: date("2026-09-08T17:36:00Z"),
            to: temporaryDirectory,
            filenameFormat: "yyyy/MM/yyyy-MM-dd",
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(result.noteURL.path, temporaryDirectory
            .appendingPathComponent("2026/09/2026-09-08.md").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.noteURL.path))
    }

    func testNonUTF8DailyNoteIsRejectedWithoutChangingIt() throws {
        let noteURL = temporaryDirectory.appendingPathComponent("2026-09-08.md")
        let original = Data([0xFF, 0xFE, 0xFD])
        try original.write(to: noteURL)

        XCTAssertThrowsError(
            try ObsidianExporter().export(
                history: sampleHistory(),
                at: date("2026-09-08T17:36:00Z"),
                to: temporaryDirectory,
                filenameFormat: "yyyy-MM-dd",
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? ObsidianExportError, .noteIsNotUTF8)
        }
        XCTAssertEqual(try Data(contentsOf: noteURL), original)
    }

    func testSymbolicLinkDailyNoteIsRejectedWithoutReplacingTheLink() throws {
        let targetURL = temporaryDirectory.appendingPathComponent("target.md")
        let noteURL = temporaryDirectory.appendingPathComponent("2026-09-08.md")
        try "Personal text.\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: noteURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(
            try ObsidianExporter().export(
                history: sampleHistory(),
                at: date("2026-09-08T17:36:00Z"),
                to: temporaryDirectory,
                filenameFormat: "yyyy-MM-dd",
                calendar: utcCalendar
            )
        ) { error in
            XCTAssertEqual(error as? ObsidianExportError, .unsupportedNoteType)
        }
        XCTAssertEqual(
            try noteURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
            true
        )
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "Personal text.\n")
    }

    private func sampleHistory() -> DailyHistory {
        let dayStart = date("2026-09-08T00:00:00Z")
        let updatedAt = date("2026-09-08T10:47:00Z")
        return DailyHistory(
            day: DateInterval(start: dayStart, duration: 24 * 60 * 60),
            sessions: [
                WorkSessionHistory(
                    id: "session",
                    startedAt: date("2026-09-08T08:47:00Z"),
                    endedAt: date("2026-09-08T10:47:00Z"),
                    correctedFromStartedAt: nil,
                    correctedFromEndedAt: nil,
                    updatedAt: updatedAt
                ),
            ],
            intervals: [
                interval("focus", .focus, "2026-09-08T08:47:00Z", "2026-09-08T09:42:00Z", updatedAt),
                interval("break", .breakTime, "2026-09-08T09:42:00Z", "2026-09-08T09:58:00Z", updatedAt),
                interval("meeting", .meeting, "2026-09-08T10:03:00Z", "2026-09-08T10:47:00Z", updatedAt),
            ]
        )
    }

    private func interval(
        _ id: String,
        _ kind: ActivityKind,
        _ start: String,
        _ end: String,
        _ updatedAt: Date
    ) -> ActivityHistoryInterval {
        ActivityHistoryInterval(
            id: id,
            sessionID: "session",
            kind: kind,
            startedAt: date(start),
            endedAt: date(end),
            source: "state_machine",
            correctedFromKind: nil,
            updatedAt: updatedAt
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
