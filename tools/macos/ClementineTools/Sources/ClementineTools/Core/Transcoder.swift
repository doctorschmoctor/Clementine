// Re-encodes a video at a chosen bitrate and size with AVAssetReader / AVAssetWriter (Apple's hardware encoders).

import AVFoundation

enum Transcoder {
    struct Settings {
        var videoBitrate: Int
        var audioBitrate: Int = 128_000
        /// Longest edge of the output, nil = as the source.
        var maxEdge: Int? = nil
        var hevc = false
    }

    static func run(_ asset: AVAsset, to url: URL, type: AVFileType, settings: Settings,
                    progress: @escaping (Double) -> Void) async throws {
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            var size = natural
            if let maxEdge = settings.maxEdge, max(size.width, size.height) > CGFloat(maxEdge) {
                let scale = CGFloat(maxEdge) / max(size.width, size.height)
                size = CGSize(width: size.width * scale, height: size.height * scale)
            }
            let width = Int(size.width / 2) * 2, height = Int(size.height / 2) * 2
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(100_000, settings.videoBitrate),
                    AVVideoExpectedSourceFrameRateKey: 30,
                ] as [String: Any],
            ])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                pairs.append((output, input))
            }
        }
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                pairs.append((output, input))
            }
        }
        guard !pairs.isEmpty else { throw ToolError("Nothing in this file can be re-encoded.") }
        guard reader.startReading() else { throw ToolError(reader.error?.localizedDescription ?? "Couldn't read the video.") }
        guard writer.startWriting() else { throw ToolError(writer.error?.localizedDescription ?? "Couldn't write the video.") }
        writer.startSession(atSourceTime: .zero)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "clementine.transcode.\(index)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if Task.isCancelled || reader.status != .reading {
                                    input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                guard let sample = output.copyNextSampleBuffer() else {
                                    input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                if index == 0, duration > 0 {
                                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                    progress(min(1, t / duration))
                                }
                                input.append(sample)
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ToolError(reader.error?.localizedDescription ?? "Reading the video failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ToolError(writer.error?.localizedDescription ?? "Writing the video failed.")
        }
    }
}
