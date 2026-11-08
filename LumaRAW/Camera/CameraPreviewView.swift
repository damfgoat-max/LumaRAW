import AVFoundation
import AVKit
import MetalKit
import SwiftUI
import UIKit

/// The cheap preview path: a plain AVCaptureVideoPreviewLayer fed directly
/// by the session. Used whenever no LUT and no image-domain monitor needs
/// the pixel pipeline.
///
/// It also hosts the hardware volume-button shutter: AVCaptureEventInteraction
/// (iOS 17.2+) is attached to this view, which lives in the window for the
/// app's whole camera session. On older systems there is no interaction and
/// the on-screen shutter button is the way to capture (see README).
struct PreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession
    var onVolumeCapture: (() -> Void)?

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
        }
    }

    final class Coordinator {
        var onVolumeCapture: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        if #available(iOS 17.2, *) {
            // Primary = volume down / Camera Control; secondary = volume
            // up (handled identically — both are shutters here).
            let interaction = AVCaptureEventInteraction(primary: { event in
                if event.phase == .ended {
                    context.coordinator.onVolumeCapture?()
                }
            }, secondary: { event in
                if event.phase == .ended {
                    context.coordinator.onVolumeCapture?()
                }
            })
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onVolumeCapture = onVolumeCapture
        if uiView.previewLayer.session != session {
            uiView.previewLayer.session = session
        }
    }
}

/// The processed preview path: the Metal view owned by the frame pipeline's
/// renderer, showing the LUT/monitor-processed frames.
struct MetalPreviewView: UIViewRepresentable {
    let renderer: MetalPreviewRenderer

    func makeUIView(context: Context) -> MTKView { renderer.mtkView }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
