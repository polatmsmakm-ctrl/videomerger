import SwiftUI
import PhotosUI
import Photos
import AVKit
import UniformTypeIdentifiers

enum Theme {
    static let accent = Color(red: 0.42, green: 0.30, blue: 0.98)
    static let accent2 = Color(red: 0.10, green: 0.58, blue: 1.0)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.11),
                                                    Color(red: 0.09, green: 0.07, blue: 0.20)],
                                           startPoint: .top, endPoint: .bottom)
    static let card = Color.white.opacity(0.08)
}

struct Clip: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in
            SentTransferredFile(m.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ZipRef: Identifiable { let url: URL; var id: URL { url } }
struct ResultRef: Identifiable { let url: URL; var id: URL { url } }

enum ImportMode { case videos, zip }

struct ContentView: View {
    @State private var clips: [Clip] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var options = MergeOptions()
    @State private var totalSeconds = 0.0
    @State private var zipRef: ZipRef?
    @State private var resultRef: ResultRef?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Circle().fill(Theme.accent.opacity(0.35)).frame(width: 300).blur(radius: 90)
                .offset(x: -140, y: -330).ignoresSafeArea()
            Circle().fill(Theme.accent2.opacity(0.25)).frame(width: 260).blur(radius: 90)
                .offset(x: 160, y: 380).ignoresSafeArea()
            VStack(spacing: 16) {
                header
                sources
                clipList
                if clips.count >= 2 { optionsCard }
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .task(id: clips.map(\.id)) { totalSeconds = await Self.totalDuration(clips) }
        .onChange(of: photoItems) { items in loadPhotos(items) }
        .sheet(item: $zipRef) { ref in
            ZipPickerView(zipURL: ref.url) { extracted in
                clips += extracted
            }
        }
        .sheet(item: $resultRef) { ref in ResultView(url: ref.url) }
        .alert("خطأ", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("VoiceMerger").font(.title2.bold())
                Text(clips.isEmpty ? "أضف مقاطعك بالترتيب" : "\(clips.count) مقاطع · \(Self.format(totalSeconds))")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
            if !clips.isEmpty {
                Button { withAnimation { clips.removeAll() } } label: {
                    Image(systemName: "trash").foregroundColor(.red.opacity(0.9))
                        .frame(width: 40, height: 40)
                        .background(Theme.card, in: Circle())
                }
            }
        }
    }

    private var sources: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $photoItems, matching: .videos) {
                SourceTile(icon: "photo.on.rectangle.angled", title: "الاستوديو", subtitle: "الصور")
            }
            Button { pickFiles(zip: false) } label: {
                SourceTile(icon: "folder.fill", title: "الملفات", subtitle: "فيديوهات")
            }
            Button { pickFiles(zip: true) } label: {
                SourceTile(icon: "doc.zipper", title: "ملف ZIP", subtitle: "مضغوط")
            }
        }
        .disabled(busy)
    }

    @ViewBuilder private var clipList: some View {
        if clips.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 44)).foregroundStyle(Theme.gradient)
                Text("ما فيه مقاطع بعد").font(.headline)
                Text("اختر من الاستوديو أو الملفات أو من ملف مضغوط")
                    .font(.footnote).foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                    ClipRow(index: i + 1, clip: clip)
                        .listRowBackground(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                            .padding(.vertical, 3))
                        .listRowSeparator(.hidden)
                }
                .onMove { clips.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { clips.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }

    private var optionsCard: some View {
        VStack(spacing: 10) {
            Picker("المقاس", selection: $options.aspect) {
                ForEach(OutputAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if options.aspect != .original {
                Toggle("ملء الإطار (قص الأطراف بدل الشريط الأسود)", isOn: $options.fill)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("الانتقال بين المقاطع").foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TransitionStyle.allCases) { t in
                            Button { options.transition = t; Haptics.tap() } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: t.icon).font(.system(size: 18))
                                    Text(t.rawValue).font(.caption2.weight(.semibold))
                                }
                                .frame(width: 72, height: 54)
                                .foregroundColor(options.transition == t ? .white : .secondary)
                                .background(options.transition == t
                                            ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.07)),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
            }
            Toggle("كتم الصوت", isOn: $options.mute)
            Toggle("جودة عالية", isOn: $options.highQuality)
        }
        .font(.footnote)
        .tint(Theme.accent2)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    nonisolated private static func totalDuration(_ clips: [Clip]) async -> Double {
        var t = 0.0
        for c in clips {
            if let d = try? await AVURLAsset(url: c.url).load(.duration) { t += d.seconds }
        }
        return t
    }

    private static func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if busy {
                ProgressView(value: progress).tint(Theme.accent2)
                Text(status).font(.footnote).foregroundColor(.secondary)
            }
            Button(action: merge) {
                HStack {
                    Image(systemName: "sparkles")
                    Text(clips.count < 2 ? "أضف مقطعين على الأقل" : "دمج \(clips.count) مقاطع")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundColor(.white)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.accent.opacity(clips.count < 2 ? 0 : 0.5), radius: 14, y: 6)
                .opacity(clips.count < 2 || busy ? 0.4 : 1)
            }
            .disabled(clips.count < 2 || busy)
        }
        .padding(.bottom, 8)
    }

    // MARK: Importing

    private func pickFiles(zip: Bool) {
        let types: [UTType] = zip ? [.zip] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        DocumentPicker.present(types: types, multiple: !zip) { urls in
            if zip {
                if let z = urls.first { zipRef = ZipRef(url: z) }
            } else {
                clips += urls.map { Clip(url: $0, name: $0.lastPathComponent) }
                Haptics.tap()
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        busy = true; status = "جاري تحميل المقاطع…"; progress = 0
        Task {
            var added: [Clip] = []
            for (i, item) in items.enumerated() {
                if let m = try? await item.loadTransferable(type: PickedMovie.self) {
                    added.append(Clip(url: m.url, name: "مقطع \(clips.count + added.count + 1)"))
                }
                progress = Double(i + 1) / Double(items.count)
            }
            clips += added
            photoItems = []
            busy = false
            if added.count < items.count { error = "تعذر تحميل \(items.count - added.count) مقطع" }
        }
    }

    // MARK: Merge

    private func merge() {
        busy = true; progress = 0; status = "جاري الدمج…"
        let urls = clips.map(\.url)
        Task {
            do {
                let out = try await Merger.merge(urls: urls, options: options) { p in
                    Task { @MainActor in progress = p }
                }
                status = "جاري الحفظ في الاستوديو…"
                try await save(out)
                Haptics.success()
                resultRef = ResultRef(url: out)
            } catch {
                self.error = error.localizedDescription
            }
            status = ""
            busy = false
        }
    }

    private func save(_ url: URL) async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

struct SourceTile: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Theme.gradient)
            VStack(spacing: 1) {
                Text(title).font(.footnote.weight(.semibold)).foregroundColor(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundColor(.secondary) }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1)))
    }
}

struct ClipRow: View {
    let index: Int
    let clip: Clip
    @State private var thumb: UIImage?
    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)").font(.footnote.bold()).foregroundColor(.white)
                .frame(width: 24, height: 24).background(Theme.gradient, in: Circle())
            ZStack {
                Color.black.opacity(0.4)
                if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).lineLimit(1).font(.subheadline.weight(.medium))
                if let duration {
                    Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .task {
            let asset = AVURLAsset(url: clip.url)
            if let d = try? await asset.load(.duration) { duration = d.seconds }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            if let r = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
                thumb = UIImage(cgImage: r.image)
            }
        }
    }
}

struct ResultView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Label("تم الدمج وحُفظ في الاستوديو", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundColor(.green).padding(.top, 24)
                if let player {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal)
                }
                ShareLink(item: url) {
                    Label("مشاركة", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundColor(.white)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal)
                Button("إغلاق") { dismiss() }.padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { player = AVPlayer(url: url) }
    }
}
