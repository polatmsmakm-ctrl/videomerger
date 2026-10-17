import UIKit
import UniformTypeIdentifiers

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// UIKit file picker. `asCopy` makes iOS copy the chosen files into the app sandbox,
/// so no security-scoped access is needed afterwards.
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: DocumentPicker?
    private let onPick: ([URL]) -> Void

    private init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

    static func present(types: [UTType], multiple: Bool, onPick: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        let delegate = DocumentPicker(onPick: onPick)
        current = delegate
        picker.delegate = delegate

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
        DocumentPicker.current = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DocumentPicker.current = nil
    }
}
