import AppKit
import BreakBarCore
import CoreAudio
import Foundation

protocol CallActivityProviding {
    func currentInputSignal() throws -> BreakCallSignal?
}

enum CallActivityMonitorStatus: Equatable {
    case monitoring
    case unavailable(String)

    var description: String {
        switch self {
        case .monitoring:
            "Monitoring"
        case .unavailable:
            "Calendar only"
        }
    }
}

struct CoreAudioCallActivityProvider: CallActivityProviding {
    func currentInputSignal() throws -> BreakCallSignal? {
        let processObjects = try audioProcessObjects()
        var dedicatedSignals: [BreakCallSignal] = []
        var browserSignals: [BreakCallSignal] = []

        for processObject in processObjects {
            // Audio clients can disappear while the process list is being
            // enumerated. Treat an individual stale object as a miss rather
            // than disabling the detector.
            guard (try? isRunningInput(processObject)) == true else {
                continue
            }
            let bundleIdentifier = try? bundleIdentifier(for: processObject)
            guard let bundleIdentifier else { continue }
            guard let signal = BreakCallApplicationClassifier.signal(for: bundleIdentifier) else {
                continue
            }
            if signal.confidence == .dedicatedApplication {
                dedicatedSignals.append(signal)
            } else {
                browserSignals.append(signal)
            }
        }

        if let dedicatedSignal = dedicatedSignals.sorted(by: {
            $0.bundleIdentifier < $1.bundleIdentifier
        }).first {
            return dedicatedSignal
        }
        return browserSignals.sorted { $0.bundleIdentifier < $1.bundleIdentifier }.first
    }

    private func audioProcessObjects() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "enumerate audio processes"
        )

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var objects = Array(repeating: AudioObjectID(0), count: count)
        try objects.withUnsafeMutableBytes { bytes in
            var mutableByteCount = byteCount
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &mutableByteCount,
                    bytes.baseAddress!
                ),
                operation: "read audio processes"
            )
        }
        return objects
    }

    private func isRunningInput(_ processObject: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &byteCount,
            &running
        )
        if status == kAudioHardwareUnknownPropertyError {
            return false
        }
        try check(status, operation: "read microphone activity")
        return running != 0
    }

    private func bundleIdentifier(for processObject: AudioObjectID) throws -> String? {
        if let coreAudioBundleIdentifier = try? coreAudioBundleIdentifier(for: processObject) {
            return coreAudioBundleIdentifier
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processIdentifier: pid_t = 0
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        try check(
            AudioObjectGetPropertyData(
                processObject,
                &address,
                0,
                nil,
                &byteCount,
                &processIdentifier
            ),
            operation: "identify audio process"
        )
        return NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
    }

    private func coreAudioBundleIdentifier(
        for processObject: AudioObjectID
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedBundleIdentifier: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(
                processObject,
                &address,
                0,
                nil,
                &byteCount,
                &unmanagedBundleIdentifier
            ),
            operation: "read audio process bundle identifier"
        )
        return unmanagedBundleIdentifier?.takeRetainedValue() as String?
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CallActivityProviderError.queryFailed(operation: operation, status: status)
        }
    }

}

private enum CallActivityProviderError: LocalizedError {
    case queryFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .queryFailed(operation, status):
            "Could not \(operation) (Core Audio error \(status))."
        }
    }
}

@MainActor
final class CallActivityMonitor: ObservableObject {
    @Published private(set) var signal: BreakCallSignal?
    @Published private(set) var status: CallActivityMonitorStatus = .monitoring

    private let provider: any CallActivityProviding
    private var debouncer = BreakCallActivityDebouncer()
    private var pollingTask: Task<Void, Never>?

    init(
        provider: any CallActivityProviding = CoreAudioCallActivityProvider(),
        pollingEnabled: Bool = true
    ) {
        self.provider = provider
        signal = nil
        guard pollingEnabled else { return }
        poll()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    private func poll() {
        let rawSignal: BreakCallSignal?
        do {
            rawSignal = try provider.currentInputSignal()
            if status != .monitoring {
                status = .monitoring
            }
        } catch {
            rawSignal = nil
            let unavailableStatus = CallActivityMonitorStatus.unavailable(
                error.localizedDescription
            )
            if status != unavailableStatus {
                status = unavailableStatus
            }
        }

        let nextSignal = debouncer.update(rawSignal: rawSignal, at: Date())
        if nextSignal != signal {
            signal = nextSignal
        }
    }
}
