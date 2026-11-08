import CoreMotion
import Foundation
import SwiftUI

// One small ObservableObject per monitoring tool. The frame pipeline writes
// to these at ~10fps from its analysis pass; only the tiny leaf views that
// display a given tool observe its store, so per-frame data NEVER triggers
// a re-render of the root camera view (the ApexCam freeze lesson).

/// RGB + luma histogram data, 64 bins each, normalized 0...1.
final class HistogramStore: ObservableObject {
    @Published var red: [Float] = [Float](repeating: 0, count: 64)
    @Published var green: [Float] = [Float](repeating: 0, count: 64)
    @Published var blue: [Float] = [Float](repeating: 0, count: 64)
    @Published var luma: [Float] = [Float](repeating: 0, count: 64)

    func update(red: [Float], green: [Float], blue: [Float], luma: [Float]) {
        self.red = red; self.green = green; self.blue = blue; self.luma = luma
    }
}

/// Pre-rendered luma waveform bitmap (rendered on the analysis queue).
final class WaveformStore: ObservableObject {
    @Published var image: CGImage?
    func update(_ image: CGImage?) { self.image = image }
}

/// Horizon level from CoreMotion device motion. Publishes the roll angle in
/// degrees relative to a level horizon; updates are throttled by the motion
/// manager's interval and a small change threshold.
final class LevelStore: ObservableObject {
    @Published var degrees: Double = 0
    @Published var isLevel: Bool = true

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var lastPublished: Double = 0

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            // Roll of the device relative to gravity, in the portrait frame.
            let roll = atan2(gravity.x, -gravity.y) * 180.0 / .pi
            guard abs(roll - self.lastPublished) > 0.2 else { return }
            self.lastPublished = roll
            DispatchQueue.main.async {
                self.degrees = roll
                self.isLevel = abs(roll) <= 1.5
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
