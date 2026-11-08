import AVFoundation
import Foundation

/// One-shot delegate for a single photo capture. The CameraManager retains
/// instances in a dictionary keyed by the settings' uniqueID until
/// `didFinishProcessingPhoto` fires, then releases them.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (AVCapturePhoto?, Error?) -> Void

    init(completion: @escaping (AVCapturePhoto?, Error?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        completion(photo, error)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error {
            completion(nil, error)
        }
    }
}
