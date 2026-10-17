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

enum TransitionStyle: String, CaseIterable, Identifiable {
    case none = "قطع مباشر", crossfade = "تلاشي", dip = "تلاشي أسود"
    case slide = "انزلاق", zoom = "تكبير", mix = "متنوع"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .none: return "scissors"
        case .crossfade: return "circle.lefthalf.filled"
        case .dip: return "moon.fill"
        case .slide: return "arrow.left.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        case .mix: return "shuffle"
        }
    }
}

struct MergeOptions {
    var aspect: OutputAspect = .original
    var fill = false
    var transition: TransitionStyle = .crossfade
    var mute = false
    var highQuality = true
}

/// Joins the given videos back to back, in order, into one MP4.
/// Clips alternate between two tracks so that neighbours can overlap during a transition.
enum Merger {
    private struct Info {
        let dur: CMTime
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let base: CGAffineTransform   // orientation, moved so the frame starts at the origin
        let size: CGSize              // oriented size
    }

    static func merge(urls: [URL], options: MergeOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        // 1. Inspect every clip.
        var infos: [Info] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else {
                throw MergeError.noVideo(url.lastPathComponent)
            }
            let natural = try await v.load(.naturalSize)
            let pt = try await v.load(.preferredTransform)
            var audio: AVAssetTrack?
            if !options.mute { audio = try await asset.loadTracks(withMediaType: .audio).first }
            let rect = CGRect(origin: .zero, size: natural).applying(pt)
            infos.append(Info(dur: dur, video: v, audio: audio,
                              base: pt.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)),
                              size: CGSize(width: abs(rect.width), height: abs(rect.height))))
        }
        let n = infos.count
        guard n > 0 else { throw MergeError.exportFailed("لا توجد مقاطع") }

        // 2. Timeline: clip i+1 starts T[i] before clip i ends.
        let wanted = CMTime(seconds: options.transition == .none ? 0 : 0.8, preferredTimescale: 600)
        var T = [CMTime](repeating: .zero, count: n)   // T[i] = overlap between clip i and i+1 (T[n-1] unused)
        var styles = [TransitionStyle](repeating: .none, count: n)
        for i in 0..<(n - 1) {
            let a = CMTimeMultiplyByRatio(infos[i].dur, multiplier: 1, divisor: 3)
            let b = CMTimeMultiplyByRatio(infos[i + 1].dur, multiplier: 1, divisor: 3)
            T[i] = CMTimeMinimum(wanted, CMTimeMinimum(a, b))
            styles[i] = options.transition == .mix
                ? [.crossfade, .dip, .slide, .zoom].randomElement()!
                : options.transition
        }
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for i in 0..<n {
            starts.append(cursor)
            cursor = CMTimeAdd(cursor, infos[i].dur)
            if i < n - 1 { cursor = CMTimeSubtract(cursor, T[i]) }
        }
        let ends = (0..<n).map { CMTimeAdd(starts[$0], infos[$0].dur) }

        // 3. Build the composition on two alternating video (and audio) tracks.
        let composition = AVMutableComposition()
        var vTracks: [AVMutableCompositionTrack] = []
        var aTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw MergeError.exportFailed("تعذر إنشاء المسارات") }
            vTracks.append(v)
            if !options.mute, let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                aTracks.append(a)
            }
        }
        let audioParams = aTracks.map { AVMutableAudioMixInputParameters(track: $0) }
        for i in 0..<n {
            let range = CMTimeRange(start: .zero, duration: infos[i].dur)
            try vTracks[i % 2].insertTimeRange(range, of: infos[i].video, at: starts[i])
            if let a = infos[i].audio, aTracks.count == 2 {
                try? aTracks[i % 2].insertTimeRange(range, of: a, at: starts[i])
                if i > 0, T[i - 1] > .zero {
                    audioParams[i % 2].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: starts[i], duration: T[i - 1]))
                }
                if i < n - 1, T[i] > .zero {
                    audioParams[i % 2].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: CMTimeSubtract(ends[i], T[i]), duration: T[i]))
                }
            }
        }

        // 4. Output frame = chosen aspect, or the first clip's oriented size (even numbers).
        let first = options.aspect.size ?? infos[0].size
        let render = CGSize(width: CGFloat(Int(first.width) / 2 * 2), height: CGFloat(Int(first.height) / 2 * 2))

        func fit(_ i: Int) -> CGAffineTransform {
            let f = infos[i]
            let sx = render.width / f.size.width, sy = render.height / f.size.height
            let s = options.fill ? max(sx, sy) : min(sx, sy)
            return f.base
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (render.width - f.size.width * s) / 2,
                                                 y: (render.height - f.size.height * s) / 2))
        }
        /// Scale `t` about the centre of the frame.
        func scaled(_ t: CGAffineTransform, by k: CGFloat) -> CGAffineTransform {
            t.concatenating(CGAffineTransform(translationX: -render.width / 2, y: -render.height / 2))
             .concatenating(CGAffineTransform(scaleX: k, y: k))
             .concatenating(CGAffineTransform(translationX: render.width / 2, y: render.height / 2))
        }
        func layer(_ i: Int, at t: CMTime) -> AVMutableVideoCompositionLayerInstruction {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: vTracks[i % 2])
            l.setTransform(fit(i), at: t)
            return l
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        func add(_ range: CMTimeRange, _ layers: [AVMutableVideoCompositionLayerInstruction]) {
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = range
            instr.layerInstructions = layers
            instructions.append(instr)
        }

        for i in 0..<n {
            // Part of clip i that plays alone.
            let soloStart = i == 0 ? starts[0] : ends[i - 1]
            let soloEnd = i == n - 1 ? ends[i] : starts[i + 1]
            if soloEnd > soloStart {
                add(CMTimeRangeFromTimeToTime(start: soloStart, end: soloEnd), [layer(i, at: soloStart)])
            }
            // Overlap with clip i+1.
            guard i < n - 1, T[i] > .zero else { continue }
            let tr = CMTimeRange(start: starts[i + 1], duration: T[i])
            let half = CMTimeMultiplyByRatio(T[i], multiplier: 1, divisor: 2)
            let firstHalf = CMTimeRange(start: tr.start, duration: half)
            let secondHalf = CMTimeRange(start: CMTimeAdd(tr.start, half), duration: half)
            let from = layer(i, at: tr.start)
            let to = layer(i + 1, at: tr.start)
            let W = render.width

            switch styles[i] {
            case .crossfade, .none, .mix:
                from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: tr)
            case .dip:
                from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: firstHalf)
                to.setOpacity(0, at: tr.start)
                to.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: secondHalf)
            case .slide:
                from.setTransformRamp(fromStart: fit(i),
                                      toEnd: fit(i).concatenating(CGAffineTransform(translationX: -W, y: 0)),
                                      timeRange: tr)
                to.setTransformRamp(fromStart: fit(i + 1).concatenating(CGAffineTransform(translationX: W, y: 0)),
                                    toEnd: fit(i + 1), timeRange: tr)
            case .zoom:
                from.setTransformRamp(fromStart: fit(i), toEnd: scaled(fit(i), by: 1.8), timeRange: tr)
                from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: tr)
                to.setTransformRamp(fromStart: scaled(fit(i + 1), by: 0.85), toEnd: fit(i + 1), timeRange: tr)
            }
            add(tr, [from, to])
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = render
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("merged-\(UUID().uuidString).mp4")
        let preset = options.highQuality ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MergeError.exportFailed("preset")
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        if !audioParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioParams
            session.audioMix = mix
        }
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
