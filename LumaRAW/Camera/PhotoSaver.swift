import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// What to write to the photo library for each capture.
enum PhotoSaveMode: String, CaseIterable, Identifiable {
    case graded    // LUT baked in (falls back to the original if no LUT)
    case original  // exactly as the sensor pipeline produced it
    case both      // original + graded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graded: return "Graded (LUT baked in)"
        case .original: return "Original only"
        case .both: return "Original + graded"
        }
    }
}

/// Writes captured photos to the Photos library, optionally into a custom
/// album named after the app. Handles the three save modes and the RAW
/// case (untouched DNG + optional LUT-graded JPEG sidecar rendered from the
/// RAW data through CIRAWFilter).
enum PhotoSaver {

    static func save(photo: AVCapturePhoto,
                     mode: PhotoSaveMode,
                     formatIsHEIF: Bool,
                     processor: LUTProcessor?,
                     useAlbum: Bool,
                     completion: @escaping (Result<Int, Error>) -> Void) {
        var payloads: [Data] = []

        if photo.isRawPhoto {
            // RAW: fileDataRepresentation() is the untouched DNG.
            guard let dng = photo.fileDataRepresentation() else {
                completion(.failure(SaveError.noData))
                return
            }
            switch mode {
            case .original:
                payloads = [dng]
            case .graded, .both:
                let sidecar = gradedSidecarData(dngData: dng, processor: processor)
                if mode == .both {
                    payloads = [dng] + (sidecar.map { [$0] } ?? [])
                } else {
                    // Graded-only for RAW means the rendered sidecar; if the
                    // RAW render fails we still save the DNG so the shot is
                    // never lost.
                    payloads = sidecar.map { [$0] } ?? [dng]
                }
            }
        } else {
            guard let original = photo.fileDataRepresentation() else {
                completion(.failure(SaveError.noData))
                return
            }
            let graded = processor.flatMap { gradedData(from: photo, processor: $0, heif: formatIsHEIF) }
            switch mode {
            case .original:
                payloads = [original]
            case .graded:
                payloads = [graded ?? original]
            case .both:
                payloads = graded.map { [original, $0] } ?? [original]
            }
        }

        writeToLibrary(payloads: payloads, useAlbum: useAlbum, completion: completion)
    }

    enum SaveError: LocalizedError {
        case noData
        case albumFailed
        var errorDescription: String? {
            switch self {
            case .noData: return "The camera returned no image data for this capture."
            case .albumFailed: return "Could not create the photo album."
            }
        }
    }

    // MARK: - Rendering graded versions

    /// pixelBuffer -> CIImage -> LUT cube -> encoded file data. The graded
    /// file is re-encoded from the full-resolution pixel buffer, with the
    /// capture's EXIF orientation applied so it displays upright.
    static func gradedData(from photo: AVCapturePhoto, processor: LUTProcessor, heif: Bool) -> Data? {
        var image: CIImage?
        if let pixelBuffer = photo.pixelBuffer {
            image = CIImage(cvPixelBuffer: pixelBuffer)
        } else if let cgImage = photo.cgImageRepresentation() {
            image = CIImage(cgImage: cgImage)
        }
        guard var ciImage = image else { return nil }
        if let rawValue = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            ciImage = ciImage.oriented(orientation)
        }
        let graded = processor.apply(to: ciImage)
        return encode(graded, heif: heif)
    }

    /// Renders a LUT-graded JPEG from RAW data: CIRAWFilter decodes the DNG
    /// with default RAW adjustments, then the same cube used for processed
    /// photos is applied. The DNG itself is saved separately, untouched.
    static func gradedSidecarData(dngData: Data, processor: LUTProcessor?) -> Data? {
        guard let rawFilter = CIRAWFilter(imageData: dngData),
              let rawImage = rawFilter.outputImage else { return nil }
        let graded = processor?.apply(to: rawImage) ?? rawImage
        return encode(graded, heif: false)
    }

    /// Encodes a CIImage via ImageIO (works for HEIC on iOS 16, where
    /// CIContext's HEIF representation API is not yet available).
    static func encode(_ image: CIImage, heif: Bool) -> Data? {
        guard let cgImage = ImageEngine.encodeContext.createCGImage(image, from: image.extent) else { return nil }
        let type = (heif ? UTType.heic : UTType.jpeg).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            // Fall back to JPEG if HEIC encoding is unavailable.
            guard let jpegDest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(jpegDest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            return CGImageDestinationFinalize(jpegDest) ? data as Data : nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Library writes

    private static func writeToLibrary(payloads: [Data],
                                       useAlbum: Bool,
                                       completion: @escaping (Result<Int, Error>) -> Void) {
        func performSave(album: PHAssetCollection?) {
            var placeholders: [PHObjectPlaceholder] = []
            PHPhotoLibrary.shared().performChanges {
                for data in payloads {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    if let placeholder = request.placeholderForCreatedAsset {
                        placeholders.append(placeholder)
                    }
                }
                if let album, let changeRequest = PHAssetCollectionChangeRequest(for: album) {
                    changeRequest.addAssets(placeholders as NSFastEnumeration)
                }
            } completionHandler: { success, error in
                if success {
                    completion(.success(payloads.count))
                } else {
                    completion(.failure(error ?? SaveError.noData))
                }
            }
        }

        guard useAlbum else { performSave(album: nil); return }
        ensureAlbum(named: AppConstants.albumName) { album in
            performSave(album: album)
        }
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    private static func ensureAlbum(named name: String, completion: @escaping (PHAssetCollection?) -> Void) {
        if let existing = fetchAlbum(named: name) {
            completion(existing)
            return
        }
        var placeholder: PHObjectPlaceholder?
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        } completionHandler: { success, _ in
            guard success, let placeholder else {
                completion(nil)
                return
            }
            let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
            completion(fetched.firstObject)
        }
    }
}
