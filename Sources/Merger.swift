import AVFoundation

enum MergeError: LocalizedError {
    case noVideo(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo(let name): return "الملف لا يحتوي فيديو: \(name)"
        case .exportFailed(let why): return "فشل التصدير: \(why)"
        }
    }
}

enum OutputAspect: String, CaseIterable, Identifiable {
    case original = "الأصلي", portrait = "عمودي 9:16", landscape = "أفقي 16:9", square = "مربع 1:1"
    var id: String { rawValue }
    var size: CGSize? {
        switch self {
        case .original: return nil
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

struct MergeOptions {
    var aspect: OutputAspect = .original
    var fill = false
    var fade = true
    var mute = false
    var highQuality = true
}

/// Joins the given videos back to back, in order, into one MP4.
/// Every clip is fitted (aspect-fit, centered) into the first clip's frame.
enum Merger {
    static func merge(urls: [URL], options: MergeOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MergeError.exportFailed("تعذر إنشاء المسارات") }

        struct Piece { let range: CMTimeRange; let transform: CGAffineTransform; let size: CGSize }
        var pieces: [Piece] = []
        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else {
                throw MergeError.noVideo(url.lastPathComponent)
            }
            let natural = try await src.load(.naturalSize)
            let pt = try await src.load(.preferredTransform)
            let range = CMTimeRange(start: .zero, duration: duration)

            try videoTrack.insertTimeRange(range, of: src, at: cursor)
            if !options.mute, let a = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: a, at: cursor)
            }

            let rect = CGRect(origin: .zero, size: natural).applying(pt)
            pieces.append(Piece(range: CMTimeRange(start: cursor, duration: duration),
                                transform: pt.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)),
                                size: CGSize(width: abs(rect.width), height: abs(rect.height))))
            cursor = CMTimeAdd(cursor, duration)
        }

        // Output frame = first clip's oriented size (even numbers for the encoder).
        let first = options.aspect.size ?? pieces[0].size
        let render = CGSize(width: CGFloat(Int(first.width) / 2 * 2), height: CGFloat(Int(first.height) / 2 * 2))

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for p in pieces {
            let sx = render.width / p.size.width, sy = render.height / p.size.height
            let s = options.fill ? max(sx, sy) : min(sx, sy)
            let fit = p.transform
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (render.width - p.size.width * s) / 2,
                                                 y: (render.height - p.size.height * s) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fit, at: p.range.start)
            if options.fade {
                let d = CMTimeMinimum(CMTime(seconds: 0.4, preferredTimescale: 600),
                                      CMTimeMultiplyByRatio(p.range.duration, multiplier: 1, divisor: 4))
                layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1,
                                     timeRange: CMTimeRange(start: p.range.start, duration: d))
                layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                     timeRange: CMTimeRange(start: CMTimeSubtract(p.range.end, d), duration: d))
            }
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = p.range
            instr.layerInstructions = [layer]
            instructions.append(instr)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = render
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        var audioMix: AVMutableAudioMix?
        if options.mute {
            composition.removeTrack(audioTrack)
        } else if options.fade {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            for p in pieces {
                let d = CMTimeMinimum(CMTime(seconds: 0.4, preferredTimescale: 600),
                                      CMTimeMultiplyByRatio(p.range.duration, multiplier: 1, divisor: 4))
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                     timeRange: CMTimeRange(start: p.range.start, duration: d))
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: CMTimeSubtract(p.range.end, d), duration: d))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("merged-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: options.highQuality ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality) else {
            throw MergeError.exportFailed("preset")
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        if let audioMix { session.audioMix = audioMix }
        session.shouldOptimizeForNetworkUse = true

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        ticker.cancel()

        guard session.status == .completed else {
            throw MergeError.exportFailed(session.error?.localizedDescription ?? "غير معروف")
        }
        progress(1)
        return out
    }
}
