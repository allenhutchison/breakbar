import BreakBarPersistence
import Darwin
import Foundation

public enum ObsidianExportError: Error, Equatable, LocalizedError, Sendable {
    case folderUnavailable
    case invalidFilenameFormat
    case unsafePathComponent
    case unsupportedNoteType
    case noteIsNotUTF8
    case markerConflict
    case noteChangedDuringExport
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            "The selected daily-notes folder is unavailable."
        case .invalidFilenameFormat:
            "The note path format must stay within the selected folder and produce a valid filename."
        case .unsafePathComponent:
            "The note path contains a symbolic link or a folder component that is not a directory."
        case .unsupportedNoteType:
            "The daily note must be a regular file, not a symbolic link or directory."
        case .noteIsNotUTF8:
            "The daily note is not valid UTF-8 text."
        case .markerConflict:
            "The daily note has missing, duplicated, or out-of-order BreakBar markers."
        case .noteChangedDuringExport:
            "The daily note changed during export. Try again to avoid overwriting another edit."
        case let .writeFailed(message):
            "The daily note could not be updated: \(message)"
        }
    }
}

public struct ObsidianExportResult: Equatable, Sendable {
    public let noteURL: URL
    public let changed: Bool

    public init(noteURL: URL, changed: Bool) {
        self.noteURL = noteURL
        self.changed = changed
    }
}

public struct ObsidianExporter: Sendable {
    public static let startMarker = "<!-- breakbar:start -->"
    public static let endMarker = "<!-- breakbar:end -->"
    public static let defaultFilenameFormat = "yyyy-MM-dd"

    public init() {}

    public func export(
        history: DailyHistory,
        at now: Date,
        to folderURL: URL,
        filenameFormat: String,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) throws -> ObsidianExportResult {
        let fileManager = FileManager.default
        let folderURL = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ObsidianExportError.folderUnavailable
        }

        let noteURL = try noteURL(
            for: history.day.start,
            in: folderURL,
            filenameFormat: filenameFormat,
            calendar: calendar
        )
        try ensureSafeParentDirectory(
            for: noteURL,
            inside: folderURL,
            createMissing: true,
            fileManager: fileManager
        )
        let originalData: Data?
        if fileManager.fileExists(atPath: noteURL.path) {
            do {
                let values = try noteURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ObsidianExportError.unsupportedNoteType
                }
                originalData = try Data(contentsOf: noteURL)
            } catch let error as ObsidianExportError {
                throw error
            } catch {
                throw ObsidianExportError.writeFailed(error.localizedDescription)
            }
        } else {
            originalData = nil
        }

        let existing: String?
        if let originalData {
            guard let decoded = String(data: originalData, encoding: .utf8) else {
                throw ObsidianExportError.noteIsNotUTF8
            }
            existing = decoded
        } else {
            existing = nil
        }

        let section = renderSection(
            history: history,
            at: now,
            calendar: calendar,
            locale: locale
        )
        let updated = try Self.updatingNote(existing, with: section)
        guard updated != existing else {
            return ObsidianExportResult(noteURL: noteURL, changed: false)
        }

        try writeAtomically(
            Data(updated.utf8),
            to: noteURL,
            inside: folderURL,
            replacing: originalData,
            fileManager: fileManager
        )
        return ObsidianExportResult(noteURL: noteURL, changed: true)
    }

    public func noteURL(
        for day: Date,
        in folderURL: URL,
        filenameFormat: String,
        calendar: Calendar = .current
    ) throws -> URL {
        let pattern = filenameFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            throw ObsidianExportError.invalidFilenameFormat
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern

        let relativePath = formatter.string(from: day)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !relativePath.contains("\n"),
              !relativePath.contains("\r")
        else {
            throw ObsidianExportError.invalidFilenameFormat
        }
        if !components[components.count - 1].lowercased().hasSuffix(".md") {
            components[components.count - 1] += ".md"
        }
        return components.dropLast().reduce(folderURL) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: true)
        }.appendingPathComponent(components.last!, isDirectory: false)
    }

    public func renderSection(
        history: DailyHistory,
        at now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let summary = history.summary(at: now)
        let sessions = history.sessions.sorted { $0.startedAt < $1.startedAt }
        let clockedIn = sessions.first.map {
            time(max(history.day.start, $0.startedAt), calendar: calendar, locale: locale)
        } ?? "—"
        let clockedOut: String
        if sessions.contains(where: { $0.endedAt == nil }) {
            clockedOut = "In progress"
        } else if let endedAt = sessions.compactMap(\.endedAt).max() {
            clockedOut = time(min(history.day.end, endedAt), calendar: calendar, locale: locale)
        } else {
            clockedOut = "—"
        }

        var lines = [
            Self.startMarker,
            "## Work",
            "",
            "**Clocked in:** \(clockedIn)  ",
            "**Clocked out:** \(clockedOut)  ",
            "**Working:** \(duration(summary.working)) · **Focus:** \(duration(summary.focus)) · **Meetings:** \(duration(summary.meetings))  ",
            "**Breaks:** \(duration(summary.breaks)) · **Lunch:** \(duration(summary.lunch)) · **Travel:** \(duration(summary.travel)) · **Away:** \(duration(summary.away))",
            "",
            "| Type | Start | End | Duration | Details |",
            "| --- | --- | --- | ---: | --- |",
        ]

        for interval in history.intervals.sorted(by: { $0.startedAt < $1.startedAt }) {
            let start = history.clippedStart(for: interval)
            let end = history.clippedEnd(for: interval, at: now)
            let endText = interval.endedAt == nil && history.contains(now)
                ? "Now"
                : time(end, calendar: calendar, locale: locale)
            lines.append(
                "| \(title(interval.kind)) | \(time(start, calendar: calendar, locale: locale)) | \(endText) | \(duration(end.timeIntervalSince(start))) | |"
            )
        }
        lines.append(Self.endMarker)
        return lines.joined(separator: "\n")
    }

    public static func updatingNote(_ existing: String?, with section: String) throws -> String {
        guard let existing else {
            return section + "\n"
        }

        let starts = existing.ranges(of: startMarker)
        let ends = existing.ranges(of: endMarker)
        if starts.isEmpty && ends.isEmpty {
            guard !existing.isEmpty else { return section + "\n" }
            let separator = existing.hasSuffix("\n\n")
                ? ""
                : existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + section + "\n"
        }

        guard starts.count == 1,
              ends.count == 1,
              starts[0].lowerBound < ends[0].lowerBound
        else {
            throw ObsidianExportError.markerConflict
        }
        return existing.replacingCharacters(
            in: starts[0].lowerBound ..< ends[0].upperBound,
            with: section
        )
    }

    private func writeAtomically(
        _ data: Data,
        to noteURL: URL,
        inside folderURL: URL,
        replacing originalData: Data?,
        fileManager: FileManager
    ) throws {
        let temporaryURL = noteURL.deletingLastPathComponent().appendingPathComponent(
            ".\(noteURL.lastPathComponent).breakbar-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        var attributes: [FileAttributeKey: Any]?
        if originalData != nil,
           let permissions = try? fileManager.attributesOfItem(atPath: noteURL.path)[.posixPermissions]
        {
            attributes = [.posixPermissions: permissions]
        }
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: attributes
        ) else {
            throw ObsidianExportError.writeFailed("Could not create a temporary file.")
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            try ensureSafeParentDirectory(
                for: noteURL,
                inside: folderURL,
                createMissing: false,
                fileManager: fileManager
            )
            try verifyDestinationUnchanged(
                at: noteURL,
                from: originalData,
                fileManager: fileManager
            )

            let renameResult: (status: Int32, errorNumber: Int32) =
                temporaryURL.withUnsafeFileSystemRepresentation { source in
                    noteURL.withUnsafeFileSystemRepresentation { destination in
                        guard let source, let destination else { return (-1, EINVAL) }
                        let status = Darwin.rename(source, destination)
                        return (status, status == 0 ? 0 : errno)
                    }
                }
            guard renameResult.status == 0 else {
                let code = POSIXErrorCode(rawValue: renameResult.errorNumber) ?? .EIO
                throw POSIXError(code)
            }
            synchronizeDirectory(noteURL.deletingLastPathComponent())
        } catch let error as ObsidianExportError {
            throw error
        } catch {
            throw ObsidianExportError.writeFailed(error.localizedDescription)
        }
    }

    private func ensureSafeParentDirectory(
        for noteURL: URL,
        inside folderURL: URL,
        createMissing: Bool,
        fileManager: FileManager
    ) throws {
        let rootComponents = folderURL.standardizedFileURL.pathComponents
        let parentComponents = noteURL.deletingLastPathComponent()
            .standardizedFileURL.pathComponents
        guard parentComponents.starts(with: rootComponents) else {
            throw ObsidianExportError.invalidFilenameFormat
        }

        var currentURL = folderURL
        for component in parentComponents.dropFirst(rootComponents.count) {
            currentURL.appendPathComponent(component, isDirectory: true)
            switch try entryType(at: currentURL) {
            case .directory:
                continue
            case .missing where createMissing:
                do {
                    try fileManager.createDirectory(
                        at: currentURL,
                        withIntermediateDirectories: false
                    )
                } catch {
                    guard try entryType(at: currentURL) == .directory else {
                        throw ObsidianExportError.writeFailed(error.localizedDescription)
                    }
                }
            case .missing, .symbolicLink, .other:
                throw ObsidianExportError.unsafePathComponent
            }
        }
    }

    private func entryType(at url: URL) throws -> FileSystemEntryType {
        var information = stat()
        let result: (status: Int32, errorNumber: Int32) =
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                let status = Darwin.lstat(path, &information)
                return (status, status == 0 ? 0 : errno)
            }
        if result.status == 0 {
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                return .directory
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        }
        if result.errorNumber == ENOENT {
            return .missing
        }
        throw POSIXError(POSIXErrorCode(rawValue: result.errorNumber) ?? .EIO)
    }

    private func verifyDestinationUnchanged(
        at url: URL,
        from originalData: Data?,
        fileManager: FileManager
    ) throws {
        let exists = fileManager.fileExists(atPath: url.path)
        guard let originalData else {
            guard !exists else { throw ObsidianExportError.noteChangedDuringExport }
            return
        }
        guard exists,
              let currentData = try? Data(contentsOf: url),
              currentData == originalData
        else {
            throw ObsidianExportError.noteChangedDuringExport
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) {
        let descriptor: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }

    private func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    private func title(_ kind: ActivityKind) -> String {
        switch kind {
        case .focus: "Focus"
        case .meeting: "Meeting"
        case .breakTime: "Break"
        case .lunch: "Lunch"
        case .travel: "Travel"
        case .away: "Away"
        }
    }
}

private enum FileSystemEntryType {
    case missing
    case directory
    case symbolicLink
    case other
}

private extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: substring, range: searchStart ..< endIndex)
        {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}
