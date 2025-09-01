
/*
ImageLoader 提示信息:
- 默认使用系统 UIImage(data:) 解码图片。
- HEIF/HEIC: iOS 11+ 系统原生支持。
- WebP: iOS 14+ 系统原生支持。
- 如果需要在 iOS 低版本支持 WebP/HEIF，可通过 setDecoder 注入自定义 ImageDecoder。
- WebPDecoder 示例可使用 SDWebImageWebPCoder 单独解码 WebP，不依赖整个 SDWebImage。
*/

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

///
/// 版权所有 / Copyright (c) 2025
/// 作者 / Author: Bighiung (大熊哥哥)
///
/// 介绍 / Introduction:
/// 这是一个轻量级的图片加载与缓存工具，支持内存缓存、磁盘缓存与请求合并。
/// This is a lightweight image loading and caching utility that supports memory cache, disk cache, and request aggregation.
///
/// 它支持自定义解码器，例如 WebP/HEIF 等格式。
/// It supports custom decoders, such as WebP/HEIF formats.
///
/// 同时提供 UI 组件的扩展方法，方便直接加载图片。
/// Also provides UI component extensions for directly loading images.
///
/// 兼容 iOS 与 macOS，并自动根据平台进行条件编译。
/// Compatible with both iOS and macOS, with conditional compilation.
///

public typealias ImageCallback = (PlatformImage?) -> Void
public typealias ImageCancelCallback = () -> Void

#if canImport(UIKit)
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
public typealias PlatformImage = NSImage
#endif

public protocol ImageDecoder {
    func decode(data: Data) -> PlatformImage?
}

class DefaultImageDecoder: ImageDecoder {
    func decode(data: Data) -> PlatformImage? {
        #if canImport(UIKit)
        return UIImage(data: data)
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }
}

public class ImageLoader {

    nonisolated(unsafe) static let shared = ImageLoader()
    private let imageCacheManager = ImageCacheManager()

    private init() {}

    public func loadImage(url: String, placeholderImage: PlatformImage?, callback: @escaping ImageCallback) -> ImageCancelCallback {
        return imageCacheManager.loadImage(url: url, callback: callback)
    }

    public func setDecoder(_ decoder: ImageDecoder) {
        imageCacheManager.decoder = decoder
    }
}

struct ImageRequest {
    let timestamp: TimeInterval
    let callback: ImageCallback
}

class ImageCacheManager {

    private let cache = NSCache<NSString, NSData>()              /// 压缩图缓存 / Compressed image cache
    private let decompressedCache = NSCache<NSString, PlatformImage>() /// 解压缩图缓存 / Decompressed image cache
    private let fileManager = FileManager.default
    private let highPrioritySerialQueue = DispatchQueue(label: "com.imageloader.queue")
    private var runningRequests: [String: [ImageRequest]] = [:]
    private let urlSession = URLSession.shared
    private let backgroundQueue = DispatchQueue.global(qos: .background)
    private let mainQueue = DispatchQueue.main
    private var cleanupTimer: DispatchSourceTimer?

    var decoder: ImageDecoder = DefaultImageDecoder()

    /// 最大并发下载数量 / Max concurrent downloads
    public var maxConcurrentDownloads: Int = 4 {
        didSet {
            semaphore = DispatchSemaphore(value: maxConcurrentDownloads)
        }
    }

    private var semaphore: DispatchSemaphore

    init(maxConcurrentDownloads: Int = 4) {
        
        self.semaphore = DispatchSemaphore(value: maxConcurrentDownloads)

        /// 注册系统通知 / Register system notifications
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clearAllCaches),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clearAllCaches),
                                               name: NSApplication.willResignActiveNotification,
                                               object: nil)
        #endif
        
        /// 创建后台 GCD 定时器 / Create background GCD timer
        setupCleanupTimer()
    }

    deinit {
        cleanupTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// 设置定时器 / Setup timer
    private func setupCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.decompressedCache.removeAllObjects()
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// 清空所有缓存 / Clear all caches
    @objc func clearAllCaches() {
        cache.removeAllObjects()
        decompressedCache.removeAllObjects()
    }

    func loadImage(url: String, callback: @escaping ImageCallback) -> ImageCancelCallback {
        /// 优先检查解压缩缓存 / Check decompressed cache first
        if let decompressedImage = decompressedCache.object(forKey: url as NSString) {
            mainQueue.async {
                callback(decompressedImage)
            }
            return {}
        }

        /// 再检查压缩缓存 / Then check compressed cache
        if let cachedData = cache.object(forKey: url as NSString),
           let compressedImage = decoder.decode(data: cachedData as Data) {
                let decompressedImage = self.decompressAndCacheImage(image: compressedImage, url: url)
                self.mainQueue.async {
                    callback(decompressedImage)
                }
            return {}
        }

        let requestTimestamp = Date().timeIntervalSince1970

        highPrioritySerialQueue.async {
            let imageRequest = ImageRequest(timestamp: requestTimestamp, callback: callback)
    
            if self.runningRequests[url] != nil {
                self.runningRequests[url]?.append(imageRequest)
                return
            }

            self.runningRequests[url] = [imageRequest]
            
            if let diskImageData = self.loadFromDisk(url: url),
               let diskImage = self.decoder.decode(data: diskImageData) {
                self.cache.setObject(diskImageData as NSData, forKey: url as NSString)
                let decompressedImage = self.decompressAndCacheImage(image: diskImage, url: url)
                self.mainQueue.async {
                    self.completeCallbacks(for: url, image: decompressedImage)
                }
                return
            }

            self.downloadImage(url: url)
        }

        return {
            self.highPrioritySerialQueue.async {
                self.runningRequests[url]?.removeAll(where: { $0.timestamp == requestTimestamp })
                if self.runningRequests[url]?.isEmpty == true {
                    self.runningRequests.removeValue(forKey: url)
                }
            }
        }
    }

    private func downloadImage(url: String) {
        // 不在 isolated 环境里，直接在串行 queue 中执行
        highPrioritySerialQueue.async { [weak self] in
            // 信号量控制并发
            guard let self = self else {
                return
            }
            self.semaphore.wait()

            guard let imageURL = URL(string: url) else {
                self.completeCallbacks(for: url, image: nil)
                self.semaphore.signal()
                return
            }

            let task = self.urlSession.dataTask(with: imageURL) { [weak self] data, _, _ in

                guard let self = self else {
                    return
                }

                defer { self.semaphore.signal() }

                guard let data = data else {
                    self.completeCallbacks(for: url, image: nil)
                    return
                }

                self.cache.setObject(data as NSData, forKey: url as NSString)
                self.saveToDisk(imageData: data, url: url)

                self.backgroundQueue.async {

                    if let image = self.decoder.decode(data: data) {
                        let decompressedImage = self.decompressAndCacheImage(image: image, url: url)
                        self.mainQueue.async {
                            self.completeCallbacks(for: url, image: decompressedImage)
                        }
                    } else {
                        self.mainQueue.async {
                            self.completeCallbacks(for: url, image: nil)
                        }
                    }
                }
            }
            task.resume()
        }
    }

    private func completeCallbacks(for url: String, image: PlatformImage?) {
        highPrioritySerialQueue.async {
            self.runningRequests[url]?.forEach { $0.callback(image) }
            self.runningRequests.removeValue(forKey: url)
        }
    }

    private func saveToDisk(imageData: Data, url: String) {
        guard let filePath = diskPath(for: url) else { return }
        try? imageData.write(to: filePath)
    }

    private func loadFromDisk(url: String) -> Data? {
        guard let filePath = diskPath(for: url), fileManager.fileExists(atPath: filePath.path) else { return nil }
        return try? Data(contentsOf: filePath)
    }

    private func diskPath(for url: String) -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let filename = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return cacheDir.appendingPathComponent(filename)
    }

    private func decompressAndCacheImage(image: PlatformImage, url: String) -> PlatformImage {
        let decompressedImage = decompressImageInBackground(image: image)
        decompressedCache.setObject(decompressedImage, forKey: url as NSString)
        return decompressedImage
    }

    private func decompressImageInBackground(image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(at: .zero)
        }
        #elseif canImport(AppKit)
        let newImage = NSImage(size: image.size)
        newImage.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #else
        return image
        #endif
    }
}

// MARK: - UI 扩展 / UI Extensions
#if canImport(UIKit)
import ObjectiveC

nonisolated(unsafe) private var imageURLKey: UInt8 = 0

public extension UIImageView {
    /// 设置网络图片 / Set image from URL
    @objc func loadImage(from url: String, placeholder: UIImage? = nil) {
        self.image = placeholder
        objc_setAssociatedObject(self, &imageURLKey, url, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        _ = ImageLoader.shared.loadImage(url: url, placeholderImage: placeholder) { [weak self] loadedImage in
            guard let self = self else { return }
            if let currentURL = objc_getAssociatedObject(self, &imageURLKey) as? String, currentURL == url {
                DispatchQueue.main.async {
                    self.image = loadedImage
                }
            }
        }
    }
}
#endif

#if canImport(AppKit)
public extension NSImageView {
    /// 设置网络图片 / Set image from URL
    func loadImage(from url: String, placeholder: NSImage? = nil) {
        self.image = placeholder
        _ = ImageLoader.shared.loadImage(url: url, placeholderImage: placeholder) { [weak self] loadedImage in
            guard let self = self else { return }
            if let currentURL = self.animator().description, currentURL == url {
                DispatchQueue.main.async {
                    self.image = loadedImage
                }
            }
        }
    }
}
#endif
