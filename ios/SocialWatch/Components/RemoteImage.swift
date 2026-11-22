import SwiftUI
import UIKit
import ImageIO

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

    /// 原始字节。
    ///
    /// 「保存到相册」要用它：界面上的 UIImage 是按屏幕分辨率解码的
    /// （见 `decode(_:maxPixelSize:)`），直接存它等于把原图降过采样。
    /// 留住原始字节，保存时原样落盘才是真正的原图。
    @Published private(set) var rawData: Data?

    /// 图片到位的回调（主线程）。
    ///
    /// 为什么还要这个：`@Published image` 只对 SwiftUI 视图有意义，
    /// 音频播放器这类非视图的调用方订阅不到 —— 它要的是「拿到 UIImage
    /// 就去设锁屏封面」。给一个一次性回调比自己再写一套下载逻辑省事得多，
    /// 而且能复用同一份内存/HTTP 缓存。
    var onImage: ((UIImage) -> Void)?

    private var task: URLSessionDataTask?
    private let session: URLSession

    /// 正在做渐进式重解码。防止捏合时把一串解码请求排进队列。
    private var isRedeccoding = false

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

    /// 只查内存缓存，不发起网络请求。给「正在播放」这类
    /// 「有就用、没有就算了」的调用方做零延迟命中用。
    static func sharedCachedImage(for remoteURL: String) -> UIImage? {
        cache.object(forKey: ("img:" + remoteURL) as NSString)
    }

    func load(itemID: Int, seq: Int, tier: ThumbTier, maxPixelSize: Int = 0) {
        let key = "\(itemID):\(seq):\(tier.rawValue):\(maxPixelSize)" as NSString
        guard let req = try? APIClient.shared.mediaRequest(itemID: itemID, seq: seq, tier: tier) else {
            failed = true
            return
        }
        load(request: req, cacheKey: key, maxPixelSize: maxPixelSize)
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

    private func load(request req: URLRequest, cacheKey key: NSString, maxPixelSize: Int = 0) {
        if let hit = ImageLoader.cache.object(forKey: key) {
            image = hit
            failed = false
            onImage?(hit)
            // 缓存命中也要把原始字节补上：放大后的渐进重解码依赖它。
            // 命中内存缓存说明同 URL 刚下过，从 URLCache 里再取一次字节很便宜。
            if rawData == nil {
                loadRawBytes(for: req)
            }
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
                guard let img = ImageLoader.decode(data, maxPixelSize: maxPixelSize) else { return }
                ImageLoader.cache.setObject(img, forKey: key)
                DispatchQueue.main.async {
                    self.image = img
                    self.rawData = data
                    self.failed = false
                    self.onImage?(img)
                }
            }
        }
        task?.resume()
    }

    /// 只取原始字节，不解码。
    ///
    /// 用于「内存缓存已命中、但还没拿到 rawData」的情况：位图直接用缓存，
    /// 但原始字节仍要补齐 —— 放大后要靠它重新解出更高清的位图。
    private func loadRawBytes(for req: URLRequest) {
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self, let data,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else { return }
            DispatchQueue.main.async { self.rawData = data }
        }.resume()
    }

    /// 按目标尺寸解码。
    ///
    /// 为什么不能一律 `UIImage(data:)`：微博原图 3024×4032、小红书原图
    /// 4284×5712，直接解码会一次性展开成 90MB 以上的位图，峰值内存能到
    /// 200MB+，这正是「放大缩小卡顿」的一大来源。
    ///
    /// ImageIO 支持「解码时直接降采样」：只产出目标尺寸那一份位图，
    /// 峰值内存大幅下降，而且用高质量重采样，清晰度不受影响。
    ///
    /// ⚠️ 注意这个上限必须与**最大缩放倍率**匹配，不是与屏幕尺寸匹配。
    /// 放大后显示的是原图的一部分：393pt 宽的屏 @3x，4x 缩放时要显示
    /// 4716 物理像素。上限低于这个数，2x 以上就开始拉伸 —— 那正是
    /// 「放大比不上微博/小红书」的原因之一。
    static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard maxPixelSize > 0,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 顺带把 EXIF 方向烘正，竖排照片不会躺倒
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// 从原始字节按新上限重新解码，供放大后换更高清的位图。
    ///
    /// 与 `load` 的区别：
    ///   * **不重新下载** —— 原始字节已经在手（`rawData`），网络零开销
    ///   * **不阻塞** —— 放到后台队列，主线程只是等结果回来再换图
    ///   * **保留旧图** —— 新位图就绪前继续显示旧的，不闪白
    ///
    /// 这条路径是「放大后清晰」的关键：1x 时用 1600px 的小位图省内存，
    /// 放大到 1.5x 以上再从同一份原始字节解出 4096px 的版本。
    /// 没有这一步，位图的分辨率永远停留在第一帧。
    ///
    /// 捏合过程中 `scrollViewDidZoom` 会连着触发几十次，所以必须防重入：
    /// 正在解的时候直接返回，别把 48MB 的解码排成一串。
    func redecode(maxPixelSize: Int) {
        guard let raw = rawData, maxPixelSize > 0 else { return }
        // 已经比目标更清晰就不折腾了
        if let cg = image?.cgImage, cg.width >= maxPixelSize { return }
        // 正在解：等它解完就好
        guard !isRedeccoding else { return }
        isRedeccoding = true

        let key = "redecode:\(maxPixelSize):\(raw.count):\(raw.prefix(16).hashValue)"
        if let hit = ImageLoader.cache.object(forKey: key as NSString) {
            isRedeccoding = false
            image = hit
            onImage?(hit)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = ImageLoader.decode(raw, maxPixelSize: maxPixelSize) else {
                DispatchQueue.main.async { self.isRedeccoding = false }
                return
            }
            ImageLoader.cache.setObject(img, forKey: key as NSString)
            DispatchQueue.main.async {
                self.isRedeccoding = false
                self.image = img
                self.onImage?(img)
            }
        }
    }
}

// MARK: - 按缩放级别重新栅格化的图片视图

/// 全屏看图用的图片视图：缩放时按新分辨率重新栅格化，避免 GPU 拉伸糊掉。
///
/// 根因（实测证据，不是推测）
/// ----------------------------
/// `UIImageView` 把 CGImage 交给 `layer.contents` 之后，CoreAnimation
/// 只按「bounds × contentsScale」栅格化**一次**，而 contentsScale 是固定
/// 的屏幕倍率。之后 UIScrollView 的缩放只是把这张栅格做 GPU 拉伸 ——
/// 越放越糊。
///
/// 实测数据：4 倍缩放时，源图里**纯黑**的 2px 网格线被插值成亮度 51 的
/// 灰线（原生重采样应当是亮度 0 的纯黑）。这就是用户说的
/// 「放大比不上微博和小红书」。
///
/// 做法
/// ----
/// 自己管理 `layer.contents`，并让 `contentsScale` 跟随当前缩放级别：
///
///   需要的栅格分辨率 = 缩放倍率 × 屏幕倍率
///   上限 = 源图像素数 ÷ 显示宽度（再高也没有额外信息）
///
/// 改完 contentsScale 后**重新赋一次 contents**，强制 CoreAnimation
/// 按新分辨率重栅格化 —— 放大后拿到的是真正的重新采样，而不是拉伸。
///
/// 为什么不用 CATiledLayer
/// ---------------------
/// 分块渲染确实更省内存，但 ImageIO 没有公开的「按区域裁剪解码」接口
/// （`kCGImageSourceCropToRect` 不是公开常量），要自己搭金字塔 +
/// 瓦片缓存，复杂且快速缩放时容易露白。本方案按缩放级别整体重栅格化，
/// 重绘发生在渲染进程，不阻塞主线程。
///
/// 为什么不用 draw(in:) 自绘
/// -----------------------
/// CALayer 的 draw(in:) 上下文是 y 向上的（实测 ctm = [3,0,0,-3,0,1608]），
/// 直接画 CGImage 会上下颠倒；手动翻转时又会把图推出可视区
/// （翻转顺序反了两次，踩坑记录在案）。改用 `layer.contents` 让
/// CoreAnimation 自己处理方向，稳得多。
final class SharpZoomImageView: UIView {
    /// 单张图解码后的最大像素边长。
    ///
    /// 为什么是 4096 而不是「屏幕长边 2556」
    /// ----------------------------------
    /// 屏幕最长边只有 2556 物理像素，但**放大后要显示的是原图的一部分**：
    /// iPhone 14 Pro 宽 393pt，缩放上限 4x、屏幕倍率 3x，4x 时横向要显示
    /// 393 × 4 × 3 = 4716 物理像素。解码上限若只按屏幕长边算，2x 以上
    /// 就会开始拉伸 —— 这正是「放大比不上微博/小红书」的一半原因
    /// （另一半是归档本身存的是 1080 宽压缩档，已在服务端修复）。
    ///
    /// 实测（4284×5712 真原图，iPhone 14 Pro 模拟）：
    ///   上限 2560 → 2x 起拉伸，4x 拉伸 2.46×
    ///   上限 4096 → 1x~2x 全 1:1 原生像素，4x 仅 1.54×
    ///
    /// 为什么不直接上 5712（= 原图全长，能做到 4x 完全 1:1）
    /// ------------------------------------------------------
    /// 位图内存会从 48MB 涨到 93MB。小红书原图最大 4284×5712，
    /// 再往上就是 90MB+ 的常驻位图 —— 用户已经反馈过「放大缩小卡顿」，
    /// 内存峰值是元凶之一。而且 4x 属于极端放大，1.54× 的拉伸在这个
    /// 级别已经很难察觉。4096 是清晰度与流畅度的平衡点。
    static let maxDecodePixelSize = 4096

    /// 1x 显示用的解码上限。1x 时整张图塞进屏幕，4096 是浪费。
    /// 1600 → 7MB 位图，滚动/翻页时内存友好。
    static let fitDecodePixelSize = 1600

    private var zoomScale: CGFloat = 1

    var image: UIImage? {
        didSet {
            layer.contents = image?.cgImage
            layer.contentsGravity = .resizeAspect
            updateRasterScale()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspect
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds 变了 →「源图像素 ÷ 显示宽度」变了，栅格上限要跟着重算
        updateRasterScale()
    }

    /// 按当前缩放级别更新栅格分辨率。
    func updateRasterScale(zoomScale: CGFloat? = nil) {
        if let z = zoomScale { self.zoomScale = z }
        guard let cg = image?.cgImage else { return }
        let w = bounds.width
        guard w > 0 else { return }
        let screen = UIScreen.main.scale
        // 源图每点最多能提供这么多像素，超过就是没有信息量的重复。
        // 这一个数就够了：位图宽度 cg.width 就是信息量的硬上限，
        // 再叠加别的上限项只会是冗余。
        let sourceLimit = CGFloat(cg.width) / w
        let wanted = self.zoomScale * screen
        // 量化到 2 的幂：捏合过程中只重栅格化几次，而不是每帧重画。
        // 每帧重画正是「放大缩小卡顿」的来源。
        var quantized = screen
        if wanted > screen * 1.2 {
            quantized = screen * pow(2, (log2(wanted / screen)).rounded())
        }
        // 不超过 sourceLimit → 永远不拉伸（1:1 原生像素）。
        let target = max(1, min(quantized, sourceLimit))
        let changed = abs(layer.contentsScale - target) > 0.01
        layer.contentsScale = target
        // 重新赋一次 contents：contentsScale 变了但 contents 对象没变时，
        // CoreAnimation 不一定会重栅格化。重新赋值能强制它按新分辨率重画。
        if changed, let cg = image?.cgImage {
            layer.contents = cg
        }
        #if DEBUG
        NSLog("[SW] raster scale=%.2f zoom=%.2f sourceW=%d boundsW=%.0f limit=%.2f",
              target, self.zoomScale, cg.width, w, sourceLimit)
        #endif
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
    /// 是否绘制「圆角 + 描边」这套卡片外观。
    ///
    /// 列表/九宫格里它是必要的：白底页面上方形图片的直角显得生硬，
    /// 描边能把图和正文分开。但在全屏黑底看图时它就是缺陷 ——
    /// 圆角会把图片四角啃掉、描边在黑底上变成一圈发亮的白边，
    /// 用户看到的就是「图片四周有一圈白边」。所以全屏态传 false。
    var showsChrome: Bool = true

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
        .clipShape(RoundedRectangle(cornerRadius: showsChrome ? 8 : 0, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: showsChrome ? 8 : 0, style: .continuous)
                .stroke(Color(red: 0.88, green: 0.88, blue: 0.86),
                        lineWidth: showsChrome ? 0.5 : 0)
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
