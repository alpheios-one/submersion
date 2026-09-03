package app.submersion

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles writing dive metadata to photos via platform channel (Android).
 *
 * Supports JPEG/PNG photos via ExifInterface, written in place.
 *
 * Videos are refused. Writing to one cannot be done in place: it meant
 * remuxing a copy, inserting a new MediaStore entry and deleting the original.
 * Submersion must never delete a user's original media (issue #1472), so the
 * path was removed rather than made non-destructive.
 */
class MetadataWriteHandler(
    context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "com.submersion.app/metadata")
    private val appContext = context.applicationContext

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "writeMetadata" -> {
                val assetId = call.argument<String>("assetId")
                val metadata = call.argument<Map<String, Any>>("metadata")
                val description = call.argument<String>("description")
                val isVideo = call.argument<Boolean>("isVideo")

                if (assetId == null || metadata == null || description == null || isVideo == null) {
                    result.error("INVALID_ARGS", "Missing required arguments", null)
                    return
                }

                writeMetadata(assetId, metadata, description, isVideo, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun writeMetadata(
        assetId: String,
        metadata: Map<String, Any>,
        description: String,
        isVideo: Boolean,
        result: MethodChannel.Result
    ) {
        try {
            // Parse the asset ID to get the MediaStore URI
            val mediaId = assetId.toLongOrNull()
            if (mediaId == null) {
                result.error("INVALID_ARGS", "Invalid asset ID format: $assetId", null)
                return
            }

            // A video cannot be edited in place. The old path remuxed a copy,
            // inserted a new MediaStore entry and deleted the original, which
            // Submersion must never do (issue #1472). Refuse instead; the UI
            // does not offer the action for a video, so this is reached only
            // by a mislabelled asset.
            if (isVideo) {
                result.error("VIDEO_UNSUPPORTED", "Writing metadata to a video is not supported.", null)
                return
            }

            // Trust MediaStore over the caller. writePhotoMetadata opens the
            // asset "rw" and hands the descriptor to ExifInterface, so a video
            // that reached it would be written into. Proceed only for
            // something MediaStore itself calls an image.
            //
            // Ask through the Files collection, not Images. Images is a view
            // over MediaProvider's files table filtered to media_type=IMAGE, so
            // a video's id appended to it resolves to no row and getType
            // returns null: the mislabelled video this check exists to catch
            // would report ASSET_NOT_FOUND rather than VIDEO_UNSUPPORTED. Files
            // is the unfiltered view, so it answers for an id from any
            // collection, which is what the iOS and macOS twins get for free
            // from PHAsset.fetchAssets(withLocalIdentifiers:).
            //
            // The volume is spelled out rather than using MediaStore
            // .VOLUME_EXTERNAL, which is API 29 and this module's minSdk is 26.
            val filesUri =
                ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), mediaId)
            val mimeType = appContext.contentResolver.getType(filesUri)
            if (mimeType == null) {
                result.error("ASSET_NOT_FOUND", "Photo not found with ID: $assetId", null)
                return
            }
            if (!mimeType.startsWith("image/")) {
                val code =
                    if (mimeType.startsWith("video/")) "VIDEO_UNSUPPORTED" else "UNSUPPORTED_FORMAT"
                result.error(code, "Writing metadata to $mimeType is not supported.", null)
                return
            }

            // Write through the Images collection. MediaProvider derives
            // media_type from the MIME type, so anything it reports as image/*
            // is in that collection, and the narrower URI keeps the descriptor
            // this opens scoped to the images the app is allowed to touch.
            val contentUri =
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId)

            writePhotoMetadata(contentUri, metadata, description, result)
        } catch (e: Exception) {
            result.error("WRITE_FAILED", "Failed to write metadata: ${e.message}", null)
        }
    }

    // MARK: - Photo Metadata

    private fun writePhotoMetadata(
        contentUri: Uri,
        metadata: Map<String, Any>,
        description: String,
        result: MethodChannel.Result
    ) {
        try {
            val resolver = appContext.contentResolver

            // Open the file for writing EXIF data
            resolver.openFileDescriptor(contentUri, "rw")?.use { pfd ->
                val exif = ExifInterface(pfd.fileDescriptor)

                // Write GPS altitude (depth as negative altitude)
                metadata["depthMeters"]?.let { depth ->
                    val depthValue = (depth as Number).toDouble()
                    // GPS altitude is stored as positive value with altitude ref indicating below/above sea level
                    exif.setAltitude(-depthValue) // Negative = below sea level
                }

                // Write GPS coordinates
                val lat = metadata["latitude"] as? Number
                val lon = metadata["longitude"] as? Number
                if (lat != null && lon != null) {
                    exif.setLatLong(lat.toDouble(), lon.toDouble())
                }

                // Write description as ImageDescription and UserComment
                exif.setAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION, description)
                exif.setAttribute(ExifInterface.TAG_USER_COMMENT, description)

                // Save the changes
                exif.saveAttributes()
            } ?: run {
                result.error("WRITE_FAILED", "Could not open file for writing", null)
                return
            }

            result.success(true)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Storage permission denied", null)
        } catch (e: Exception) {
            result.error("WRITE_FAILED", "Failed to write EXIF: ${e.message}", null)
        }
    }
}
