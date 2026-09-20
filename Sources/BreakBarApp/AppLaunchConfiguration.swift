import Foundation

struct AppLaunchConfiguration: Equatable {
    enum Mode: Equatable {
        case standard
        case demo
        case uiTest(UITestScenario)
    }

    enum UITestScenario: String, Equatable {
        case settingsPrivacy = "settings-privacy"
    }

    static let uiTestReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    let mode: Mode
    let databaseURL: URL?

    var isDemoMode: Bool {
        mode == .demo
    }

    var isUITestMode: Bool {
        if case .uiTest = mode { return true }
        return false
    }

    var uiTestScenario: UITestScenario? {
        guard case let .uiTest(scenario) = mode else { return nil }
        return scenario
    }

    var referenceDate: Date? {
        isUITestMode ? Self.uiTestReferenceDate : nil
    }

    static var current: AppLaunchConfiguration {
        parse(arguments: CommandLine.arguments)
    }

    static func parse(
        arguments: [String],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AppLaunchConfiguration {
        guard arguments.contains("--ui-test") else {
            return AppLaunchConfiguration(
                mode: arguments.contains("--demo") ? .demo : .standard,
                databaseURL: nil
            )
        }

        let scenario = argumentValue(after: "--ui-test-scenario", in: arguments)
            .flatMap(UITestScenario.init(rawValue:))
            ?? .settingsPrivacy
        let requestedDatabaseURL = argumentValue(
            after: "--ui-test-database",
            in: arguments
        ).map { URL(fileURLWithPath: $0) }
        let databaseURL = requestedDatabaseURL.flatMap {
            validatedUITestDatabaseURL($0, temporaryDirectory: temporaryDirectory)
        } ?? generatedUITestDatabaseURL(temporaryDirectory: temporaryDirectory)

        return AppLaunchConfiguration(
            mode: .uiTest(scenario),
            databaseURL: databaseURL
        )
    }

    private static func argumentValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex]
        return value.hasPrefix("--") ? nil : value
    }

    private static func validatedUITestDatabaseURL(
        _ databaseURL: URL,
        temporaryDirectory: URL
    ) -> URL? {
        let temporaryRoot = temporaryDirectory.standardizedFileURL.path
        let candidate = databaseURL.standardizedFileURL
        guard candidate.pathExtension == "sqlite",
              candidate.path.hasPrefix(temporaryRoot + "/")
        else {
            return nil
        }
        return candidate
    }

    private static func generatedUITestDatabaseURL(
        temporaryDirectory: URL
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent("BreakBarUITests-\(UUID().uuidString).sqlite")
    }
}
