import AVFoundation
import SwiftUI

/// Exposure tab: Auto/Manual toggle, ISO, shutter, EV compensation.
struct ExposurePanel: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                SegmentedButtons(options: [("AUTO", true), ("MANUAL", false)],
                                 selection: $viewModel.autoExposure)
                Spacer()
                Text(viewModel.autoExposure ? "Auto exposure" : "Manual exposure")
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
            ProSlider(title: "ISO",
                      value: $viewModel.iso,
                      range: Double(viewModel.capabilities.minISO)...Double(viewModel.capabilities.maxISO),
                      logScale: true,
                      format: FormatHelpers.iso,
                      disabled: viewModel.autoExposure)
            ProSlider(title: "SHUTTER",
                      value: $viewModel.shutterSeconds,
                      range: viewModel.capabilities.minShutter...viewModel.capabilities.maxShutter,
                      logScale: true,
                      format: FormatHelpers.shutter,
                      disabled: viewModel.autoExposure)
            ProSlider(title: "EV",
                      value: $viewModel.evBias,
                      range: Double(viewModel.capabilities.minEV)...Double(viewModel.capabilities.maxEV),
                      format: FormatHelpers.ev)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Focus tab: AF/MF toggle, manual focus position, AE/AF lock.
struct FocusPanel: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                SegmentedButtons(options: [("AF", true), ("MF", false)],
                                 selection: $viewModel.autoFocus)
                Spacer()
                Button {
                    viewModel.toggleAEAFLock()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.aeafLocked ? "lock.fill" : "lock.open")
                        Text(viewModel.aeafLocked ? "AE/AF LOCKED" : "AE/AF LOCK")
                    }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(viewModel.aeafLocked ? Color.red : Theme.raised)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            ProSlider(title: "FOCUS",
                      value: $viewModel.focusPosition,
                      range: 0...1,
                      format: { $0 < 0.02 ? "Macro" : ($0 > 0.98 ? "∞" : "\(Int($0 * 100))%") },
                      disabled: viewModel.autoFocus)
            Text("Tap the preview to focus · long-press locks AE/AF")
                .font(.caption2)
                .foregroundColor(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// White balance tab: auto/manual, Kelvin + tint, one-tap presets.
struct WBPanel: View {
    @ObservedObject var viewModel: CameraViewModel

    private let presets: [(String, Double)] = [
        ("Tungsten", 3200), ("Fluoro", 4000), ("Daylight", 5500),
        ("Cloudy", 6500), ("Shade", 7500)
    ]

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                SegmentedButtons(options: [("AUTO", true), ("MANUAL", false)],
                                 selection: $viewModel.autoWB)
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) {
                                viewModel.autoWB = false
                                viewModel.tint = 0
                                viewModel.kelvin = preset.1
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(!viewModel.autoWB && Int(viewModel.kelvin) == Int(preset.1) ? Theme.accent : Theme.raised)
                            .foregroundColor(!viewModel.autoWB && Int(viewModel.kelvin) == Int(preset.1) ? .black : .white)
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ProSlider(title: "KELVIN",
                      value: $viewModel.kelvin,
                      range: 2000...9000,
                      format: FormatHelpers.kelvin,
                      disabled: viewModel.autoWB)
            ProSlider(title: "TINT",
                      value: $viewModel.tint,
                      range: -100...100,
                      format: { String(format: "%+.0f", $0) },
                      disabled: viewModel.autoWB)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Monitor tab: scopes, zebra, peaking, false color, level, grids, guides.
struct MonitorPanel: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    monitorToggle("Histogram", isOn: $viewModel.monitors.histogram)
                    monitorToggle("Waveform", isOn: $viewModel.monitors.waveform)
                    monitorToggle("Level", isOn: $viewModel.showLevel)
                }
                HStack(spacing: 16) {
                    monitorToggle("False color", isOn: $viewModel.monitors.falseColor)
                    monitorToggle("Zebra", isOn: $viewModel.monitors.zebra)
                    monitorToggle("Peaking", isOn: $viewModel.monitors.peaking)
                }
                if viewModel.monitors.zebra {
                    ProSlider(title: "ZEBRA",
                              value: Binding(get: { Double(viewModel.monitors.zebraThreshold) },
                                             set: { viewModel.monitors.zebraThreshold = Float($0) }),
                              range: 0.5...1.0,
                              format: { "\(Int($0 * 100))%" })
                }
                if viewModel.monitors.peaking {
                    HStack(spacing: 8) {
                        Text("PEAK")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.textDim)
                            .frame(width: 58, alignment: .leading)
                        ForEach(PeakingColor.allCases) { color in
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(viewModel.monitors.peakingColor == color ? Theme.accent : Color.white.opacity(0.25),
                                                         lineWidth: viewModel.monitors.peakingColor == color ? 2.5 : 1))
                                .onTapGesture { viewModel.monitors.peakingColor = color }
                        }
                    }
                }
                HStack {
                    Text("GRID")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textDim)
                        .frame(width: 58, alignment: .leading)
                    SegmentedButtons(options: GridType.allCases.map { ($0.title, $0) },
                                     selection: $viewModel.gridType)
                }
                HStack {
                    Text("GUIDE")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textDim)
                        .frame(width: 58, alignment: .leading)
                    SegmentedButtons(options: AspectGuide.allCases.map { ($0.title, $0) },
                                     selection: $viewModel.aspectGuide)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func monitorToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .fixedSize()
    }
}
