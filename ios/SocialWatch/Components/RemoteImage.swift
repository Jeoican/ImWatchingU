import SwiftUI
import UIKit

/// 带鉴权的图片视图。
///
/// 为什么不能用 AsyncImage
/// ----------------------
/// `AsyncImage` 只接受一个 URL，无法附加 `Authorization` 头。
/// 而本项目所有图片接口都要 Bearer 凭证，所以必须自己取字节再解码。
/// 这同时带来两个好处：
///   1. 能显式控制档位（thumb=2 小图 / thumb=1 预览 / 原图）
///   2. 能复用 URLSession 的 ETag 缓存，同一张图重复进出不再下载
///
/// 三层缓存
/// --------
/// 内存（NSCache，按 URL）→ URLSession 磁盘/HTTP 缓存（后端已发 ETag）
/// → 网络。列表滚动时同一张图反复进出，内存层能避免重复解码。
final class ImageLoader: ObservableObject {
    static let shared = ImageLoader()

    @Published private(set) var image: UIImage?
    @Published private(set) var failed = false

    private var task: URLSessionDataTask?
    private let session: URLSession

    /// 解码后的 UIImage 缓存（内存，进程内）。上限按张数：100 张 900px
    /// 预览图约 30–40MB，现代设备可接受。
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    /// HTTP 磁盘缓存：后端对图片发 `public, max-age=86400` + ETag，
    /// 落盘后杀进程重启也不重下命中 304。系统共享 URLCache 磁盘容量偏小，
    /// 这里给独立的大容量缓存，确保头像/封面/归档图都能留住。
    private static let urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                           diskCapacity: 100 * 1024 * 1024,
                                           diskPath: "sw_http_images")

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = Self.urlCache
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        session = URLSession(configuration: cfg)
    }

    deinit { task?.cancel() }

    func load(itemID: Int, seq: Int, tier: ThumbTier) {
        let key = "\(itemID):\(seq):\(tier.rawValue)" as NSString
        guard let req = try? APIClient.shared.mediaRequest(itemID: itemID, seq: seq, tier: tier) else {
            failed = true
            return
        }
        load(request: req, cacheKey: key)
    }

    /// 任意远程 URL 经后端 `/api/img` 代理取图（头像、歌单封面）。
    func load(remoteURL: String) {
        guard !remoteURL.isEmpty,
              let req = try? APIClient.shared.remoteImageRequest(url: remoteURL) else {
            failed = true
            return
        }
        load(request: req, cacheKey: ("img:" + remoteURL) as NSString)
    }

    private func load(request req: URLRequest, cacheKey key: NSString) {
        if let hit = ImageLoader.cache.object(forKey: key) {
            image = hit
            failed = false
            return
        }

        task?.cancel()
        task = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if err != nil { return }
            guard let data, let http = resp as? HTTPURLResponse else { return }
            // 401 不是"图片坏了"，而是凭证失效，交给上层处理
            guard http.statusCode == 200 || http.statusCode == 206 else { return }

            // 解码放到后台：4MB 的 JPEG 解成位图要几百毫秒，
            // 在主线程做会让滚动明显掉帧。
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = UIImage(data: data) else { return }
                ImageLoader.cache.setObject(img, forKey: key)
                DispatchQueue.main.async {
                    self.image = img
                    self.failed = false
                }
            }
        }
        task?.resume()
    }
}

/// 单个图片格子。
///
/// 骨架屏而不是空白：图片有 100–300ms 的下载期，空白会让列表
/// 看起来像"没加载出来"。先占好 aspect-ratio 的位置，图到了再淡入，
/// 视觉上不会跳。
struct RemoteImage: View {
    let itemID: Int
    let seq: Int
    let tier: ThumbTier
    let aspectRatio: Double

    @StateObject private var loader = ImageLoader()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = loader.image {
                    Image(uiImage: img)
                        .resizable()
                        // fit 而不是 fill。web 端最初用 fill 把 4284×5712 的竖图
                        // 裁到只剩 48% 高度，用户以为"图碎了"。这里绝不再犯。
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.88, green: 0.88, blue: 0.86), lineWidth: 0.5)
        )
        .onAppear {
            loader.load(itemID: itemID, seq: seq, tier: tier)
        }
        .animation(.easeIn(duration: 0.18), value: loader.image != nil)
    }

    private var placeholder: some View {
        ZStack {
            Color(red: 0.96, green: 0.96, blue: 0.95)
            if loader.failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 20))
                    .foregroundColor(.gray.opacity(0.5))
            } else {
                ProgressView().scaleEffect(0.7)
            }
        }
    }
}

/// 远程 URL 图片（头像、歌单封面）经 `/api/img` 代理加载。
/// 加载失败时降级显示首字母，与 web 端头像占位逻辑一致。
struct ProxyImage: View {
    let url: String?
    let placeholderText: String
    var circular: Bool = false

    @StateObject private var loader = ImageLoader()

    var body: some View {
        ZStack {
            if let img = loader.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if loader.failed || url == nil || url?.isEmpty == true {
                Text(String(placeholderText.prefix(1)))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.53))
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .background(Color(red: 0.94, green: 0.94, blue: 0.93))
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
        .onAppear { if let url, !url.isEmpty { loader.load(remoteURL: url) } }
    }
}

// 让 circular 三元能统一类型
struct AnyShape: Shape, @unchecked Sendable {
    private let _path: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { _path = shape.path(in:) }
    func path(in rect: CGRect) -> Path { _path(rect) }
}
