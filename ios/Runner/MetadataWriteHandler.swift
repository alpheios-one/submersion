import Flutter
import Photos
import AVFoundation
import CoreLocation
import ImageIO
import MobileCoreServices

/// Handles writing dive metadata to photos via platform channel.
///
/// Supports JPEG/HEIC/HEIF photos via CGImageDestination, edited in place so
/// the asset keeps its identity and the user keeps Revert to Original.
///
/// Videos are refused. Writing to one cannot be done in place: it meant
/// exporting a copy, creating a new asset and deleting the original.
/// Submersion must never delete a user's original media (issue #1472), so the
/// path was removed rather than made non-destructive. Live Photos are refused
/// for a related reason (issue #795).
class MetadataWriteHandler: NSObject {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.submersion.app/metadata",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "writeMetadata":
            guard let args = call.arguments as? [String: Any],
                  let assetId = args["assetId"] as? String,
                  let metadata = args["metadata"] as? [String: Any],
                  let description = args["description"] as? String,
                  let isVideo = args["isVideo"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
                return
            }

            writeMetadata(
                assetId: assetId,
                metadata: metadata,
                description: description,
                isVideo: isVideo,
                result: result
            )

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func writeMetadata(
        assetId: String,
        metadata: [String: Any],
        description: String,
        isVideo: Bool,
        result: @escaping FlutterResult
    ) {
        // Check photo library authorization
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            result(FlutterError(
                code: "PERMISSION_DENIED",
                message: "Photo library access not authorized",
                details: nil
            ))
            return
        }

        // Find the asset
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            result(FlutterError(
                code: "ASSET_NOT_FOUND",
                message: "Asset not found with ID: \(assetId)",
                details: nil
            ))
            return
        }

        if isVideo {
            // A video cannot be edited in place. The old path exported a copy,
            // created a new asset and deleted the original, which Submersion
            // must never do (issue #1472). Refuse instead; the UI does not
            // offer the action for a video, so this only catches a mislabelled
            // asset.
            print("[MetadataWriteHandler] Asset is a video; metadata writing is not supported")
            result(FlutterError(
                code: "VIDEO_UNSUPPORTED",
                message: "Writing metadata to a video is not supported.",
                details: nil
            ))
            return
        }

        // Check if asset is editable
        guard asset.canPerform(.properties) else {
            result(FlutterError(
                code: "READ_ONLY",
                message: "Asset cannot be modified (may be in iCloud or shared album)",
                details: nil
            ))
            return
        }

        if asset.mediaSubtypes.contains(.photoLive) {
            // A Live Photo is a still paired with a short video. Photos' content
            // editing session expects the output to represent both resources, so
            // the plain-image round-trip in writePhotoMetadata is rejected with
            // PHPhotosErrorDomain error 3302. Refuse up front with a code the
            // Dart layer can translate rather than surfacing that raw error.
            result(FlutterError(
                code: "LIVE_PHOTO_UNSUPPORTED",
                message: "Live Photos cannot be edited in place without breaking the paired video.",
                details: nil
            ))
        } else {
            writePhotoMetadata(asset: asset, metadata: metadata, description: description, result: result)
        }
    }

    // MARK: - Photo Metadata

    private func writePhotoMetadata(
        asset: PHAsset,
        metadata: [String: Any],
        description: String,
        result: @escaping FlutterResult
    ) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        asset.requestContentEditingInput(with: options) { [weak self] input, info in
            guard let self = self, let input = input else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not get content editing input",
                        details: nil
                    ))
                }
                return
            }

            guard let inputURL = input.fullSizeImageURL else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not get image URL",
                        details: nil
                    ))
                }
                return
            }

            // Read existing image data
            guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not read image source",
                        details: nil
                    ))
                }
                return
            }

            // Get existing metadata
            var existingMetadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]

            // Build GPS metadata
            var gpsDict = existingMetadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

            if let depth = metadata["depthMeters"] as? Double {
                gpsDict[kCGImagePropertyGPSAltitude as String] = abs(depth)
                gpsDict[kCGImagePropertyGPSAltitudeRef as String] = 1 // Below sea level
            }

            if let lat = metadata["latitude"] as? Double,
               let lon = metadata["longitude"] as? Double {
                gpsDict[kCGImagePropertyGPSLatitude as String] = abs(lat)
                gpsDict[kCGImagePropertyGPSLatitudeRef as String] = lat >= 0 ? "N" : "S"
                gpsDict[kCGImagePropertyGPSLongitude as String] = abs(lon)
                gpsDict[kCGImagePropertyGPSLongitudeRef as String] = lon >= 0 ? "E" : "W"
            }

            existingMetadata[kCGImagePropertyGPSDictionary as String] = gpsDict

            // Build TIFF metadata for description
            var tiffDict = existingMetadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiffDict[kCGImagePropertyTIFFImageDescription as String] = description
            existingMetadata[kCGImagePropertyTIFFDictionary as String] = tiffDict

            // Build EXIF metadata
            var exifDict = existingMetadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exifDict[kCGImagePropertyExifUserComment as String] = description
            existingMetadata[kCGImagePropertyExifDictionary as String] = exifDict

            // Create output
            let output = PHContentEditingOutput(contentEditingInput: input)
            let outputURL = output.renderedContentURL

            // Determine UTI based on original file
            let uti = self.getImageUTI(for: inputURL)

            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                uti,
                1,
                nil
            ) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not create image destination",
                        details: nil
                    ))
                }
                return
            }

            // Copy the image with updated metadata
            CGImageDestinationAddImageFromSource(destination, imageSource, 0, existingMetadata as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "WRITE_FAILED",
                        message: "Could not finalize image with metadata",
                        details: nil
                    ))
                }
                return
            }

            // Set adjustment data (required for Photos to accept the edit)
            let adjustmentData = PHAdjustmentData(
                formatIdentifier: "com.submersion.app.metadata",
                formatVersion: "1.0",
                data: description.data(using: .utf8) ?? Data()
            )
            output.adjustmentData = adjustmentData

            // Commit the changes
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest(for: asset)
                request.contentEditingOutput = output
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        result(true)
                    } else {
                        result(FlutterError(
                            code: "WRITE_FAILED",
                            message: error?.localizedDescription ?? "Failed to save changes",
                            details: nil
                        ))
                    }
                }
            }
        }
    }

    private func getImageUTI(for url: URL) -> CFString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "heic", "heif":
            return AVFileType.heic as CFString
        case "png":
            return kUTTypePNG
        case "jpg", "jpeg":
            return kUTTypeJPEG
        default:
            return kUTTypeJPEG
        }
    }
}
