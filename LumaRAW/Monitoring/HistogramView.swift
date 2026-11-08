import SwiftUI

/// Leaf view: observes ONLY the HistogramStore, so histogram updates at
/// ~10fps re-render this small view and nothing else.
struct HistogramView: View {
    @ObservedObject var store: HistogramStore

    var body: some View {
        Canvas { context, size in
            func area(_ bins: [Float], color: Color) {
                guard bins.count > 1 else { return }
                var path = Path()
                let stepX = size.width / CGFloat(bins.count - 1)
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    let y = size.height - CGFloat(min(max(v, 0), 1)) * size.height
                    path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.45)))
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
            }
            area(store.red, color: .red)
            area(store.green, color: .green)
            area(store.blue, color: .blue)
            area(store.luma, color: .white)
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .accessibilityLabel("Histogram")
    }
}
