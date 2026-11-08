import Foundation
import SwiftUI
import UIKit

/// Slow-moving system facts for the status bar (battery + free storage).
/// Lives in its own store so the 30-second refresh timer never touches the
/// camera view model.
final class SystemStatusStore: ObservableObject {
    @Published var batteryPercent: Int = -1
    @Published var isCharging = false
    @Published var storageText: String = ""

    private var timer: Timer?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update),
                                               name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func update() {
        let device = UIDevice.current
        batteryPercent = device.batteryLevel >= 0 ? Int(device.batteryLevel * 100) : -1
        isCharging = device.batteryState == .charging || device.batteryState == .full
        if let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            storageText = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        }
    }

    var batterySymbol: String {
        if isCharging { return "battery.100.bolt" }
        switch batteryPercent {
        case 75...100: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        case 0..<25: return "battery.25"
        default: return "battery.0"
        }
    }
}

/// Top status bar: resolution, format, active LUT, lens, battery, storage.
struct StatusBarView: View {
    @ObservedObject var viewModel: CameraViewModel
    @EnvironmentObject var lutManager: LUTManager
    @StateObject private var system = SystemStatusStore()

    var body: some View {
        HStack(spacing: 10) {
            Text("\(viewModel.resolution.title) · \(viewModel.format.title)")
                .fontWeight(.bold)
                .foregroundColor(.white)
            if let lutName = lutManager.selectedItem?.name {
                HStack(spacing: 3) {
                    Image(systemName: "wand.and.stars")
                    Text(lutName)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .foregroundColor(Theme.accent)
            }
            Spacer()
            if let lens = viewModel.selectedLens {
                Text(lens.label)
                    .foregroundColor(Theme.textDim)
            }
            if !system.storageText.isEmpty {
                Text(system.storageText)
                    .foregroundColor(Theme.textDim)
            }
            HStack(spacing: 3) {
                Image(systemName: system.batterySymbol)
                if system.batteryPercent >= 0 {
                    Text("\(system.batteryPercent)%")
                }
            }
            .foregroundColor(system.batteryPercent >= 0 && system.batteryPercent <= 20 && !system.isCharging ? .red : Theme.textDim)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.black)
    }
}
