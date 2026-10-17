import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers

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

struct ContentView: View {
    @State private var clips: [Clip] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showZipImporter = false
    @State private var zipURL: URL?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var result: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if clips.isEmpty {
                    Spacer()
                    Text("أضف المقاطع بالترتيب اللي تبي يندمجون فيه")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                            HStack {
                                Text("\(i + 1)").bold().frame(width: 28)
                                Text(clip.name).lineLimit(1)
                            }
                        }
                        .onMove { clips.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { clips.remove(atOffsets: $0) }
                    }
                }

                VStack(spacing: 12) {
                    HStack {
                        PhotosPicker(selection: $photoItems, matching: .videos) {
                            Label("من الاستوديو", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button { showFiles = true } label: {
                            Label("من الملفات", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button { showZipImporter = true } label: {
                        Label("من ملف مضغوط (ZIP)", systemImage: "doc.zipper")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if busy {
                        ProgressView(value: progress)
                        Text(status).font(.footnote).foregroundColor(.secondary)
                    }
                    Button(action: merge) {
                        Text("دمج \(clips.count) مقاطع").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clips.count < 2 || busy)

                    if let result {
                        ShareLink(item: result) {
                            Label("مشاركة الفيديو المدموج", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("دمج الفيديو")
            .toolbar { if !clips.isEmpty { EditButton() } }
            .onChange(of: photoItems) { items in loadPhotos(items) }
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { loadFiles(urls) }
            }
            .fileImporter(isPresented: $showZipImporter, allowedContentTypes: [.zip]) { r in
                if case .success(let url) = r { zipURL = url }
            }
            .sheet(item: Binding(get: { zipURL.map { ZipRef(url: $0) } }, set: { if $0 == nil { zipURL = nil } })) { ref in
                ZipPickerView(zipURL: ref.url) { extracted in
                    clips += extracted
                }
            }
            .alert("خطأ", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("حسناً", role: .cancel) {}
            } message: { Text(error ?? "") }
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
        }
    }

    private func loadFiles(_ urls: [URL]) {
        busy = true; status = "جاري نسخ الملفات…"; progress = 0
        Task.detached {
            var added: [Clip] = []
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    added.append(Clip(url: dest, name: url.lastPathComponent))
                }
            }
            await MainActor.run {
                clips += added
                busy = false
            }
        }
    }

    private func merge() {
        busy = true; result = nil; progress = 0; status = "جاري الدمج…"
        let urls = clips.map(\.url)
        Task {
            do {
                let out = try await Merger.merge(urls: urls) { p in
                    Task { @MainActor in progress = p }
                }
                status = "جاري الحفظ في الاستوديو…"
                try await save(out)
                result = out
                status = "تم الحفظ في الاستوديو ✅"
            } catch {
                self.error = error.localizedDescription
                status = ""
            }
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
