# ImageLoader

A lightweight, extensible image loader for iOS & MacOS. 轻量级、可扩展的 iOS/MacOS 图片加载器。

Features memory & disk caching, request aggregation, background decoding, and pluggable decoders for modern formats like **WebP** and **HEIF**.\
支持内存与磁盘缓存、请求聚合、后台解码，以及对 **WebP** 和 **HEIF** 等现代格式的解码扩展。

&#x20;&#x20;

---

## ✨ Features / 特性

- 🧠 **Memory cache / 内存缓存** (stores compressed `UIImage`, reduces RAM usage 存储压缩后的 `UIImage`，节省内存)
- 💾 **Disk cache / 磁盘缓存** (stores raw compressed `Data` 存储压缩数据)
- 🔄 **Request aggregation / 请求聚合** (multiple requests for the same URL are merged 多个相同 URL 的请求会合并)
- ⚡ **Background decoding / 后台解码** (main thread stays smooth 主线程不卡顿)
- 🎨 **Custom decoders / 自定义解码器** (support WebP/HEIF on older iOS versions 在低版本 iOS 上支持 WebP/HEIF)
- 🎯 **Configurable concurrency / 可配置并发** (limit max simultaneous requests 限制最大同时请求数)

---

## 📦 Installation / 安装

### CocoaPods

```ruby
pod 'SwiftImageLoader'
```

### Swift Package Manager (SPM) / Swift 包管理器

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/myinter/SwiftImageLoader.git", from: "1.0.0")
]
```

---

## 🚀 Usage / 使用示例

```swift
import SwiftImageLoader

// Basic usage / 基本用法
ImageLoader.shared.loadImage(
    url: "https://example.com/image.jpg",
    placeholderImage: UIImage(named: "placeholder")
) { image in
    imageView.image = image
}

// UIImageView loads image with method in extension / 使用UIImageView扩展加载
aImageView.loadImage(from: "https://example.com/image.jpg",
                    placeholder: nil)

```

---

## 🔧 Custom Decoders / 自定义解码器

By default, ImageLoader uses system decoders (`UIImage` / `NSImage`). 默认使用系统解码器 (`UIImage` / `NSImage`)。 For **WebP** or **HEIF** on older iOS versions, you can plug in your own decoder.\
在低版本 iOS 中，可以注入自定义解码器来支持 **WebP** 或 **HEIF**。

```swift
// Example: Inject a WebP decoder / 例子：注入 WebP 解码器
ImageLoader.shared.setDecoder(WebPDecoder())

ImageLoader.shared.loadImage(url: "https://example.com/image.webp") { image in
    imageView.image = image
}
```

### 📌 System format support / 系统格式支持

- **JPEG / PNG / GIF** → Supported natively since early iOS / iOS 早期已原生支持
- **WebP** → iOS 14+ native, lower versions need custom decoder / iOS 14+ 原生支持，低版本需自定义解码器
- **HEIF / HEIC** → iOS 11+ native, lower versions need custom decoder / iOS 11+ 原生支持，低版本需自定义解码器

---

## 📂 Caching / 缓存机制

- **Memory cache / 内存缓存** → Stores compressed `UIImage`, decompressed only when needed 存储压缩图像，按需解压
- **Disk cache / 磁盘缓存** → Saves compressed `Data` 保存压缩数据
- **Request aggregation / 请求聚合** → Same URL requests share one download 相同 URL 请求共享下载

---

## 🛠 Advanced / 高级用法

### Concurrency / 并发控制

```swift
ImageLoader.shared.maxConcurrentDownloads = 4
```

### Cache Management / 缓存管理

```swift
// Clear memory cache / 清除内存缓存
ImageLoader.shared.clearMemoryCache()

// Clear disk cache / 清除磁盘缓存
ImageLoader.shared.clearDiskCache()
```

---

## 📄 License / 开源协议

ImageLoader is available under the MIT license.\
ImageLoader 采用 MIT 协议开源。\
---

## ❤️ Contributing / 贡献

Pull requests and feature requests are welcome! 欢迎提交 Pull Request 和新功能建议！\
If you find an issue, please open a GitHub Issue with details. 如果发现问题，请提交 Issue 并附详细说明。

