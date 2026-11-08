import SwiftUI

/// Leaf view: displays the pre-rendered luma waveform bitmap from the
/// WaveformStore. The bitmap is produced on the analysis queue, so this
/// view does zero per-frame computation itself.
struct WaveformView: View {
    @ObservedObject var store: WaveformStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if let image = store.image {
                Image(decorative: image, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            // IRE scale hints: two faint lines at 0% and 100%.
            VStack {
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                Spacer()
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .accessibilityLabel("Waveform monitor")
    }
}
