import SwiftUI
import ZIPFoundation

private let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "3gp"]

struct ZipEntryInfo: Identifiable {
    let path: String
    let size: Int
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Lists the videos inside a ZIP, lets the user tick them in order, extracts only those.
struct ZipPickerView: View {
    let zipURL: URL
    let onDone: ([Clip]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ZipEntryInfo] = []
    @State private var selected: [String] = []   // paths, in tap order
    @State private var busy = true
    @State private var status = "جاري قراءة الملف…"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack {
                if busy {
                    Spacer(); ProgressView(status); Spacer()
                } else if let error {
                    Spacer(); Text(error).foregroundColor(.red).padding(); Spacer()
                } else if entries.isEmpty {
                    Spacer(); Text("ما فيه فيديوهات داخل الملف").foregroundColor(.secondary); Spacer()
                } else {
                    List(entries) { e in
                        Button { toggle(e.path) } label: {
                            HStack {
                                if let i = selected.firstIndex(of: e.path) {
                                    Text("\(i + 1)").bold().foregroundColor(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(Color.accentColor))
                                } else {
                                    Image(systemName: "circle").foregroundColor(.secondary).frame(width: 26)
                                }
                                VStack(alignment: .leading) {
                                    Text(e.name).lineLimit(1).foregroundColor(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    Button(action: extract) {
                        Text("إضافة \(selected.count) مقاطع").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                    .padding()
                }
            }
            .navigationTitle(zipURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
            .task { await load() }
        }
    }

    private func toggle(_ path: String) {
        if let i = selected.firstIndex(of: path) { selected.remove(at: i) } else { selected.append(path) }
    }

    private func load() async {
        let url = zipURL
        let result: Result<[ZipEntryInfo], Error> = await Task.detached {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let archive = try Archive(url: url, accessMode: .read)
                var list: [ZipEntryInfo] = []
                for entry in archive where entry.type == .file {
                    let ext = (entry.path as NSString).pathExtension.lowercased()
                    let name = (entry.path as NSString).lastPathComponent
                    if videoExts.contains(ext), !name.hasPrefix("."), !entry.path.hasPrefix("__MACOSX") {
                        list.append(ZipEntryInfo(path: entry.path, size: Int(entry.uncompressedSize)))
                    }
                }
                list.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                return .success(list)
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let l): entries = l
        case .failure(let e): error = "تعذر فتح الملف: \(e.localizedDescription)"
        }
        busy = false
    }

    private func extract() {
        busy = true; status = "جاري استخراج المقاطع المحددة…"
        let url = zipURL, paths = selected
        Task {
            let result: Result<[Clip], Error> = await Task.detached {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let archive = try Archive(url: url, accessMode: .read)
                    var clips: [Clip] = []
                    for path in paths {
                        guard let entry = archive[path] else { continue }
                        let name = (path as NSString).lastPathComponent
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(UUID().uuidString)-\(name)")
                        _ = try archive.extract(entry, to: dest)
                        clips.append(Clip(url: dest, name: name))
                    }
                    return .success(clips)
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let c): onDone(c); dismiss()
            case .failure(let e): error = "فشل الاستخراج: \(e.localizedDescription)"; busy = false
            }
        }
    }
}
