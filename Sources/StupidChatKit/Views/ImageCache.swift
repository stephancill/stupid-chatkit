import CryptoKit
import UIKit

/// Downloaded images by URL (and by key), shared by the chat and the rest of the app.
///
/// Small images that identify someone (avatars) can also be kept on disk, stale-while-revalidate: once seen, they
/// draw in the first frame on every later launch, even when the network hands out a new URL for the same picture
/// (looked up by a stable key), and are downloaded again at most once a launch, replacing what shows only when it
/// changed.
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let keyedCache = NSCache<NSString, UIImage>()
    private var loads: [URL: Task<UIImage?, Never>] = [:]
    /// Kept images (`persist`) downloaded this launch, so their disk copies aren't fresh until then.
    private var revalidated: Set<URL> = []
    private let directory: URL
    /// The kept images beyond which the oldest go; avatars are a few kilobytes each.
    private nonisolated static let diskLimit = 3000

    private init() {
        // Limited by decoded size, not count: a feed's worth of avatars is small, story slides are large.
        cache.totalCostLimit = 150 * 1024 * 1024
        keyedCache.countLimit = 300
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "kept-images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory
        Task.detached(priority: .background) { Self.prune(directory) }
    }

    public func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    public func setImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
    }

    public func image(forKey key: String) -> UIImage? {
        keyedCache.object(forKey: key as NSString)
    }

    public func setImage(_ image: UIImage, forKey key: String) {
        keyedCache.setObject(image, forKey: key as NSString)
    }

    /// The image to draw now: from memory, else (for kept images) the copy on disk by URL or key, which a later
    /// `load(url:key:persist:)` refreshes.
    public func cachedImage(url: URL?, key: String?, persist: Bool) -> UIImage? {
        if let url, let image = image(for: url) {
            return image
        }
        if let key, let image = image(forKey: key) {
            return image
        }
        guard persist else { return nil }
        for name in [url.map { Self.fileName($0.absoluteString) }, key.map(Self.fileName)].compactMap(\.self) {
            guard let data = try? Data(contentsOf: directory.appending(path: name)), let image = UIImage(data: data) else { continue }
            if let url {
                setImage(image, for: url)
            }
            if let key {
                setImage(image, forKey: key)
            }
            return image
        }
        return nil
    }

    /// Whether a kept image still needs its download this launch.
    public func needsRevalidation(url: URL) -> Bool {
        !revalidated.contains(url)
    }

    public func preload(url: URL) {
        guard image(for: url) == nil, loads[url] == nil else { return }
        Task { await load(url: url) }
    }

    /// Loads a kept image ahead of showing it: read from disk and decoded off the main thread, so a row scrolling
    /// in draws it without decoding, then downloaded once a launch.
    public func preload(url: URL, key: String?, persist: Bool) {
        guard persist else {
            preload(url: url)
            return
        }
        if image(for: url) == nil, (key.map { image(forKey: $0) } ?? nil) == nil, !diskReads.contains(url) {
            diskReads.insert(url)
            let files = [Self.fileName(url.absoluteString)] + (key.map { [Self.fileName($0)] } ?? [])
            let directory = directory
            Task {
                let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    for name in files {
                        guard let data = try? Data(contentsOf: directory.appending(path: name)), let image = UIImage(data: data) else { continue }
                        return image.preparingForDisplay() ?? image
                    }
                    return nil
                }.value
                diskReads.remove(url)
                guard let decoded, image(for: url) == nil else { return }
                setImage(decoded, for: url)
                if let key {
                    setImage(decoded, forKey: key)
                }
            }
        }
        guard needsRevalidation(url: url), loads[url] == nil else { return }
        Task { await load(url: url, key: key, persist: true) }
    }

    /// Kept images being read from disk ahead of showing them.
    private var diskReads: Set<URL> = []

    /// Downloads and decodes `url` off the main thread, joining a load already in flight for it.
    @discardableResult
    public func load(url: URL) async -> UIImage? {
        await load(url: url, key: nil, persist: false)
    }

    /// Downloads `url`, joining a load in flight; a kept image (`persist`) downloads once a launch even when cached,
    /// and is written to disk under its URL and key.
    @discardableResult
    public func load(url: URL, key: String?, persist: Bool) async -> UIImage? {
        if let cached = image(for: url), !persist || revalidated.contains(url) {
            return cached
        }
        if let inFlight = loads[url] {
            return await inFlight.value
        }
        let names = persist ? [Self.fileName(url.absoluteString)] + (key.map { [Self.fileName($0)] } ?? []) : []
        let directory = directory
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return nil }
            if !names.isEmpty {
                Task.detached(priority: .utility) {
                    for name in names {
                        try? data.write(to: directory.appending(path: name), options: .atomic)
                    }
                }
            }
            return await image.byPreparingForDisplay() ?? image
        }
        loads[url] = task
        let image = await task.value
        loads[url] = nil
        if let image {
            setImage(image, for: url)
            if let key {
                setImage(image, forKey: key)
            }
            if persist {
                revalidated.insert(url)
            }
        }
        return image
    }

    private nonisolated static func fileName(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys), files.count > diskLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - diskLimit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}
