import SwiftUI

/// Shared visual identity: near-black surfaces, one amber accent.
enum Theme {
    static let accent = Color(red: 0.96, green: 0.66, blue: 0.18)
    static let panel = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let raised = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let textDim = Color(red: 0.62, green: 0.62, blue: 0.64)
}

enum FormatHelpers {
    static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1f\"", seconds) }
        if seconds <= 0 { return "—" }
        let denom = Int((1.0 / seconds).rounded())
        return "1/\(max(denom, 1))"
    }
    static func iso(_ value: Double) -> String { "\(Int(value.rounded()))" }
    static func ev(_ value: Double) -> String { String(format: "%+.1f", value) }
    static func kelvin(_ value: Double) -> String { "\(Int(value.rounded()))K" }
}

/// A Blackmagic-style horizontal value slider: label on the left, a track
/// with tick marks and an amber knob, formatted value on the right. Drag
/// anywhere on the track to change the value; supports log scaling for
/// ISO / shutter ranges.
struct ProSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logScale: Bool = false
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var disabled: Bool = false

    private var fraction: Double {
        if logScale {
            let lo = log(range.lowerBound), hi = log(range.upperBound)
            guard hi > lo else { return 0 }
            return min(max((log(max(value, range.lowerBound)) - lo) / (hi - lo), 0), 1)
        }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func valueForFraction(_ f: Double) -> Double {
        if logScale {
            let lo = log(range.lowerBound), hi = log(range.upperBound)
            return exp(lo + (hi - lo) * f)
        }
        return range.lowerBound + (range.upperBound - range.lowerBound) * f
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textDim)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Tick marks
                    HStack {
                        ForEach(0..<21) { i in
                            Rectangle()
                                .fill(Color.white.opacity(i % 5 == 0 ? 0.35 : 0.15))
                                .frame(width: 1, height: i % 5 == 0 ? 12 : 7)
                            if i < 20 { Spacer() }
                        }
                    }
                    .frame(height: 14)
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 4)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(geo.size.width * fraction, 4), height: 4)
                    Circle()
                        .fill(disabled ? Color.gray : Theme.accent)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                        .position(x: geo.size.width * fraction, y: 10)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !disabled, geo.size.width > 0 else { return }
                            let f = min(max(drag.location.x / geo.size.width, 0), 1)
                            value = valueForFraction(f)
                        }
                )
            }
            .frame(height: 20)
            Text(format(value))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundColor(disabled ? Theme.textDim : .white)
                .frame(width: 64, alignment: .trailing)
        }
        .opacity(disabled ? 0.55 : 1)
        .padding(.vertical, 4)
    }
}

/// Small segmented A/B style selector used by the control panels.
struct SegmentedButtons<T: Hashable>: View {
    let options: [(title: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selection == option.value ? Theme.accent : Theme.raised)
                        .foregroundColor(selection == option.value ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The readout row under the preview: live ISO / shutter / EV / WB / focus
/// values. Tapping a value jumps to the tab that controls it (Blackmagic
/// workflow). Reads the view model's throttled exposure info — never
/// per-frame data.
struct ReadoutRow: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        HStack(spacing: 0) {
            item(title: "ISO",
                 value: FormatHelpers.iso(Double(viewModel.exposureInfo.iso)),
                 active: !viewModel.autoExposure) { viewModel.activeTab = .exposure }
            divider
            item(title: "SHUTTER",
                 value: FormatHelpers.shutter(viewModel.exposureInfo.shutterSeconds),
                 active: !viewModel.autoExposure) { viewModel.activeTab = .exposure }
            divider
            item(title: "EV",
                 value: FormatHelpers.ev(Double(viewModel.exposureInfo.evBias)),
                 active: abs(viewModel.evBias) > 0.01) { viewModel.activeTab = .exposure }
            divider
            item(title: "WB",
                 value: viewModel.autoWB ? "AUTO" : FormatHelpers.kelvin(Double(viewModel.exposureInfo.kelvin)),
                 active: !viewModel.autoWB) { viewModel.activeTab = .wb }
            divider
            item(title: "FOCUS",
                 value: viewModel.aeafLocked ? "LOCK" : (viewModel.autoFocus ? "AF" : "\(Int(viewModel.exposureInfo.lensPosition * 100))%"),
                 active: !viewModel.autoFocus || viewModel.aeafLocked) { viewModel.activeTab = .focus }
        }
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 26)
    }

    private func item(title: String, value: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textDim)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundColor(active ? Theme.accent : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
