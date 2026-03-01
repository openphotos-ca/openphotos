import Foundation
import CoreHaptics

final class HapticsManager {
    static let shared = HapticsManager()

    private var engine: CHHapticEngine?
    private var supportsHaptics: Bool = false

    private init() {
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        supportsHaptics = capabilities.supportsHaptics
        if supportsHaptics {
            createEngine()
        }
    }

    private func createEngine() {
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = true
            engine?.resetHandler = { [weak self] in
                guard let self else { return }
                do {
                    try self.engine?.start()
                } catch {
                    // Swallow errors silently; haptics are best-effort
                }
            }
        } catch {
            engine = nil
            supportsHaptics = false
        }
    }

    private func startIfNeeded() {
        guard supportsHaptics else { return }
        do { try engine?.start() } catch { /* no-op */ }
    }

    // MARK: Public patterns

    // Light tick for add
    func playAdd() {
        playTransient(intensity: 0.5, sharpness: 0.7, relativeTime: 0.0)
    }

    // Medium tick for remove
    func playRemove() {
        playTransient(intensity: 0.8, sharpness: 0.6, relativeTime: 0.0)
    }

    // Error notification-style pattern
    func playError() {
        guard supportsHaptics else { return }
        startIfNeeded()
        let events: [CHHapticEvent] = [
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
                          ],
                          relativeTime: 0.0),
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                          ],
                          relativeTime: 0.12)
        ]
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            // no-op
        }
    }

    // MARK: Helpers

    private func playTransient(intensity: Float, sharpness: Float, relativeTime: TimeInterval) {
        guard supportsHaptics else { return }
        startIfNeeded()
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: relativeTime
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            // no-op
        }
    }
}

