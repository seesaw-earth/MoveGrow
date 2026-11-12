// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Thumbnails are decoded off the main thread with ImageIO at the size they are drawn
// (not the stored size) and kept in memory, so scrolling the album never decodes JPEGs on the
// main thread and never shows the same image twice from disk.

import SwiftUI
import UIKit
import ImageIO

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var keysByName: [String: Set<String>] = [:]

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private static func key(_ name: String, _ maxPixel: Int) -> String { "\(name)#\(maxPixel)" }

    /// Already decoded (synchronous, for the first frame of a cell).
    func cached(_ name: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: Self.key(name, maxPixel) as NSString)
    }

    func image(_ name: String, maxPixel: Int) async -> UIImage? {
        let key = Self.key(name, maxPixel)
        if let image = cache.object(forKey: key as NSString) { return image }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inflight[key] { return running }
            let task = Task.detached(priority: .userInitiated) { Self.decode(LocalFiles.url(name), maxPixel: maxPixel) }
            inflight[key] = task
            keysByName[name, default: []].insert(key)
            return task
        }
        let image = await task.value
        lock.withLock { inflight[key] = nil }
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// Drops every cached size of a file that was rewritten or deleted.
    func invalidate(_ name: String) {
        let keys = lock.withLock { keysByName.removeValue(forKey: name) ?? [] }
        for key in keys { cache.removeObject(forKey: key as NSString) }
    }

    static func decode(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,          // decode here, not during the first draw
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A square-filling thumbnail from album storage, decoded asynchronously.
struct Thumbnail: View {
    let filename: String?
    var maxPixel: Int
    @State private var image: UIImage?

    init(filename: String?, maxPixel: Int = 360) {
        self.filename = filename
        self.maxPixel = maxPixel
        _image = State(initialValue: filename.flatMap { ThumbnailCache.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                .transition(.opacity)
            } else if filename == nil {
                Image(systemName: "video").foregroundStyle(.secondary).font(.title2)
            }
        }
        .clipped()
        .task(id: filename) {
            guard let filename else { image = nil; return }
            if let cached = ThumbnailCache.shared.cached(filename, maxPixel: maxPixel) { image = cached; return }
            let loaded = await ThumbnailCache.shared.image(filename, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}
