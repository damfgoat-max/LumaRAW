import SwiftUI

/// Composition grid overlays drawn over the preview (pure geometry — no
/// camera data involved).
struct GridOverlayView: View {
    let type: GridType

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { path in
                switch type {
                case .off:
                    break
                case .thirds:
                    for f in [CGFloat(1) / 3, CGFloat(2) / 3] {
                        path.move(to: CGPoint(x: w * f, y: 0))
                        path.addLine(to: CGPoint(x: w * f, y: h))
                        path.move(to: CGPoint(x: 0, y: h * f))
                        path.addLine(to: CGPoint(x: w, y: h * f))
                    }
                case .center:
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                case .golden:
                    // Golden-ratio division lines (~0.382 / 0.618).
                    for f in [CGFloat(0.382), CGFloat(0.618)] {
                        path.move(to: CGPoint(x: w * f, y: 0))
                        path.addLine(to: CGPoint(x: w * f, y: h))
                        path.move(to: CGPoint(x: 0, y: h * f))
                        path.addLine(to: CGPoint(x: w, y: h * f))
                    }
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Aspect-ratio frame guide: dims everything outside the guide rectangle.
struct AspectGuideView: View {
    let ratio: CGFloat // width / height

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect: CGRect = {
                if size.width / size.height > ratio {
                    let w = size.height * ratio
                    return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
                } else {
                    let h = size.width / ratio
                    return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
                }
            }()
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle()
                    .path(in: rect)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Horizon level leaf view — observes ONLY the LevelStore.
struct LevelOverlayView: View {
    @ObservedObject var store: LevelStore

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Capsule()
                    .fill(store.isLevel ? Color.green : Theme.accent)
                    .frame(width: 130, height: 3)
                    .rotationEffect(.degrees(-store.degrees))
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
            }
            .frame(height: 24)
            Text(String(format: "%.1f°", abs(store.degrees)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(store.isLevel ? .green : Theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
        }
        .allowsHitTesting(false)
    }
}

/// Focus reticle shown briefly where the user tapped.
struct FocusReticleView: View {
    let normalizedPoint: CGPoint
    let locked: Bool

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .stroke(locked ? Color.red : Theme.accent, lineWidth: 1.5)
                .frame(width: 52, height: 52)
                .position(x: normalizedPoint.x * geo.size.width,
                          y: normalizedPoint.y * geo.size.height)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Shown when camera permission is denied, with a route into Settings.
struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 44))
                .foregroundColor(Theme.accent)
            Text("Camera access is off")
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Text("\(AppConstants.appName) needs the camera to work. Enable it in Settings → \(AppConstants.appName) → Camera.")
                .font(.callout)
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.accent)
            .foregroundColor(.black)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
