import UIKit

/*
ImageLoader 提示信息:
- 默认使用系统 UIImage(data:) 解码图片。
- HEIF/HEIC: iOS 11+ 系统原生支持。
- WebP: iOS 14+ 系统原生支持。
- 如果需要在 iOS 低版本支持 WebP/HEIF，可通过 setDecoder 注入自定义 ImageDecoder。
- WebPDecoder 示例可使用 SDWebImageWebPCoder 单独解码 WebP，不依赖整个 SDWebImage。
*/

typealias ImageCallback = (UIImage?) -> Void
typealias ImageCancelCallback = () -> Void

protocol ImageDecoder {
    func decode(data: Data) -> UIImage?
}

class DefaultImageDecoder: ImageDecoder {
    func decode(data: Data) -> UIImage? {
        return UIImage(data: data)
    }
}

class ImageLoader: ImageHandler {
    static let shared = ImageLoader()
    private let imageCacheManager = ImageCacheManager()
    
    private init() {}
    
    func loadImage(url: String, placeholderImage: UIImage?, callback: @escaping ImageCallback) -> ImageCancelCallback {
        return imageCacheManager.loadImage(url: url, callback: callback)
    }
    
    func setDecoder(_ decoder: ImageDecoder) {
        imageCacheManager.decoder = decoder
    }
}

struct ImageRequest {
    let timestamp: TimeInterval
    let callback: ImageCallback
}

class ImageCacheManager {
    private let cache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.imageloader.queue") // 串行队列，保证请求聚合逻辑在同一队列
    private var runningRequests: [String: [ImageRequest]] = [:]
    private let urlSession = URLSession.shared // 单例 URLSession
    private let backgroundQueue = DispatchQueue.global(qos: .background) // 单例后台队列
    private let mainQueue = DispatchQueue.main // 单例主队列
    
    var decoder: ImageDecoder = DefaultImageDecoder() // 可配置的解码器
    
    func loadImage(url: String, callback: @escaping ImageCallback) -> ImageCancelCallback {
        // 内存缓存优先（无需聚合，直接返回）
        if let cachedData = cache.object(forKey: url as NSString),
           let compressedImage = decoder.decode(data: cachedData as Data) {
            backgroundQueue.async {
                let decompressedImage = self.decompressImageInBackground(image: compressedImage)
                self.mainQueue.async {
                    callback(decompressedImage)
                }
            }
            return {}
        }
        
        var requestTimestamp: TimeInterval = 0
        
        // 串行队列处理磁盘缓存检查与请求聚合逻辑
        queue.async {
            requestTimestamp = Date().timeIntervalSince1970
            let imageRequest = ImageRequest(timestamp: requestTimestamp, callback: callback)
            
            if self.runningRequests[url] != nil {
                // 已经有请求在跑，直接挂上去
                self.runningRequests[url]?.append(imageRequest)
                return
            }
            
            // 第一个请求
            self.runningRequests[url] = [imageRequest]
            
            // 优先查磁盘
            if let diskImageData = self.loadFromDisk(url: url),
               let diskImage = self.decoder.decode(data: diskImageData) {
                self.cache.setObject(diskImageData as NSData, forKey: url as NSString)
                let decompressedImage = self.decompressImageInBackground(image: diskImage)
                self.mainQueue.async {
                    self.completeCallbacks(for: url, image: decompressedImage)
                }
                return
            }
            
            // 磁盘也没有，走网络
            self.downloadImage(url: url)
        }
        
        return { [weak self] in
            self?.queue.async {
                self?.runningRequests[url]?.removeAll(where: { $0.timestamp == requestTimestamp })
                if self?.runningRequests[url]?.isEmpty == true {
                    self?.runningRequests.removeValue(forKey: url)
                }
            }
        }
    }
    
    private func downloadImage(url: String) {
        guard let imageURL = URL(string: url) else {
            completeCallbacks(for: url, image: nil)
            return
        }
        
        urlSession.dataTask(with: imageURL) { [weak self] data, _, _ in
            guard let self = self, let data = data else {
                self?.completeCallbacks(for: url, image: nil)
                return
            }
            
            self.cache.setObject(data as NSData, forKey: url as NSString)
            self.saveToDisk(imageData: data, url: url)
            
            self.backgroundQueue.async {
                if let image = self.decoder.decode(data: data) {
                    let decompressedImage = self.decompressImageInBackground(image: image)
                    self.mainQueue.async {
                        self.completeCallbacks(for: url, image: decompressedImage)
                    }
                } else {
                    self.mainQueue.async {
                        self.completeCallbacks(for: url, image: nil)
                    }
                }
            }
        }.resume()
    }
    
    private func completeCallbacks(for url: String, image: UIImage?) {
        queue.async {
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
    
    private func decompressImageInBackground(image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(at: .zero)
        }
    }
}
