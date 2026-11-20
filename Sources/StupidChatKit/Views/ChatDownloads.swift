import UIKit
import UniformTypeIdentifiers

/// Saving files into the user's Downloads folder on a Mac, as Mac apps save. An iPhone app there is sandboxed, so the
/// user picks the folder once (the picker opens at Downloads) and a security-scoped bookmark keeps access to it.
@MainActor
public enum ChatDownloads {
    private static let bookmarkKey = "StupidChatKit.downloadsFolderBookmark"

    /// Copies `file` into the Downloads folder under its own name (numbered when one exists) and returns where it went.
    /// Asks for the folder the first time, or when access has been lost; throws `CancellationError` if the user
    /// declines.
    public static func save(_ file: URL, from presenter: UIViewController) async throws -> URL {
        if let folder = grantedFolder(), let saved = try? copy(file, into: folder) {
            return saved
        }
        let folder = try await askForFolder(from: presenter)
        return try copy(file, into: folder)
    }

    private static func grantedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, let fresh = try? bookmark(url) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private static func bookmark(_ url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        return try url.bookmarkData()
    }

    private static func copy(_ file: URL, into folder: URL) throws -> URL {
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        let destination = freeName(for: file, in: folder)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// "clip.mp4", else "clip 2.mp4", "clip 3.mp4", as Finder names copies.
    private static func freeName(for file: URL, in folder: URL) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var candidate = folder.appending(path: file.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    private static func askForFolder(from presenter: UIViewController) async throws -> URL {
        let choose = await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Save to Downloads",
                message: "Choose your Downloads folder once, and photos and videos will save there from now on.",
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Choose…", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
        guard choose else { throw CancellationError() }
        let folder = try await FolderPicker.pick(from: presenter, startingAt: userDownloads)
        try UserDefaults.standard.set(bookmark(folder), forKey: bookmarkKey)
        return folder
    }

    /// The user's real Downloads folder, not the sandbox container's, for the picker to open at.
    private static var userDownloads: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appending(path: "Downloads", directoryHint: .isDirectory)
    }
}

/// A folder picker that answers once: the folder chosen, or `CancellationError`.
@MainActor
private final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    /// Kept while the picker is open, since it holds its delegate weakly.
    private static var open: FolderPicker?

    static func pick(from presenter: UIViewController, startingAt directory: URL?) async throws -> URL {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = directory
        let delegate = FolderPicker()
        picker.delegate = delegate
        open = delegate
        defer { open = nil }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            presenter.present(picker, animated: true)
        }
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let folder = urls.first {
            continuation?.resume(returning: folder)
        } else {
            continuation?.resume(throwing: CancellationError())
        }
        continuation = nil
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
