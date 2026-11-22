import SwiftUI
import UIKit
import AVFoundation

// MARK: - 抖音个人主页式入口
//
// 切到抖音标签先看到「个人主页」：头像/昵称 + 作品宫格。
// 点某张作品才进入下面的沉浸式图文+音乐页。
// 这样和抖音的个人页→作品浏览路径一致，也避免一进标签就被扔进全屏 feed。

struct DouyinProfileView: View {
    let items: [ArchiveItem]
    let hasMore: Bool
    let loadMore: () -> Void

    private struct PlayerSelection: Identifiable {
        let id = UUID()
        let index: Int
    }

    private enum ProfileTab: Int {
        case works, recommended
    }

    @State private var tab: ProfileTab = .works
    @State private var isSearching = false
    @State private var query = ""
    @State private var playerSelection: PlayerSelection?
    @State private var authorName = "抖音创作者"
    @State private var authorAvatar: String?
    @State private var didAutoOpen = false

    private var displayedItems: [ArchiveItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [ArchiveItem]
        if q.isEmpty {
            base = items
        } else {
            base = items.filter { $0.cleanText.localizedCaseInsensitiveContains(q) }
        }
        // 「推荐」没有服务端排序，用本地点赞数做确定性排序，
        // 不伪造数据，也不引入额外接口。
        return tab == .recommended
            ? base.sorted { ($0.likes ?? 0) > ($1.likes ?? 0) }
            : base
    }

    private var totalLikes: Int {
        items.reduce(0) { $0 + max(0, $1.likes ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                profileHeader
                tabs
                if items.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载抖音作品…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if displayedItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("没有找到相关作品")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    workGrid
                    if hasMore {
                        Button {
                            loadMore()
                        } label: {
                            HStack {
                                Spacer()
                                Text("加载更多")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(height: 44)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 24)
        }
        .background(Color.white)
        .task(id: items.first?.id) { await loadAuthor() }
        #if DEBUG
        // 模拟器不能注入点击：SW_DEBUG_OPENFEED=1 直接进第一张作品。
        .onAppear { autoOpenFeedIfNeeded() }
        .onChange(of: displayedItems.count) { _ in autoOpenFeedIfNeeded() }
        #endif
        .fullScreenCover(item: $playerSelection) { sel in
            DouyinFeedView(
                items: displayedItems,
                initialIndex: sel.index,
                hasMore: hasMore,
                loadMore: loadMore,
                onDismiss: { playerSelection = nil },
                onSearch: {
                    playerSelection = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isSearching = true
                    }
                }
            )
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProxyImage(url: authorAvatar,
                           placeholderText: authorName,
                           circular: true)
                    .frame(width: 56, height: 56)
                    .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(authorName)
                            .font(.system(size: 17, weight: .semibold))
                        // 装饰性标签：这个归档页没有私信能力，不做成假按钮。
                        Text("私信")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                    Text("已归档作品 · 图文与音乐")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    isSearching.toggle()
                    if !isSearching { query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray6))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索作品")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜你想看的", text: $query)
                        .font(.system(size: 14))
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
                .padding(.horizontal, 14)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 26) {
            Text("作品 \(items.count)")
                .font(.system(size: 14, weight: tab == .works ? .semibold : .regular))
                .foregroundColor(tab == .works ? .primary : .secondary)
                .onTapGesture { tab = .works }
            Text("推荐 \(items.count)")
                .font(.system(size: 14, weight: tab == .recommended ? .semibold : .regular))
                .foregroundColor(tab == .recommended ? .primary : .secondary)
                .onTapGesture { tab = .recommended }
            Spacer()
            Text("获赞 \(Self.compact(totalLikes))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .overlay(
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var workGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
            spacing: 2
        ) {
            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { idx, item in
                Button {
                    playerSelection = PlayerSelection(index: idx)
                } label: {
                    DouyinGridTile(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    #if DEBUG
    private func autoOpenFeedIfNeeded() {
        guard !didAutoOpen, !displayedItems.isEmpty,
              ProcessInfo.processInfo.environment["SW_DEBUG_OPENFEED"] == "1" else { return }
        didAutoOpen = true
        playerSelection = PlayerSelection(index: 0)
    }
    #endif

    private func loadAuthor() async {
        guard let id = items.first?.id else { return }
        do {
            let d = try await APIClient.shared.archiveItem(id: id)
            await MainActor.run {
                authorName = d.authorName ?? "抖音创作者"
                authorAvatar = d.authorAvatar
            }
        } catch {
            // 头像昵称只是外观，取不到不影响宫格与播放。
        }
    }

    private static func compact(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// 宫格封面：3:4 竖图裁成方块，右下角点赞/日期，多张图带角标。
private struct DouyinGridTile: View {
    let item: ArchiveItem
    @StateObject private var loader = ImageLoader()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let img = loader.image {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Color(red: 0.94, green: 0.94, blue: 0.93)
                        if loader.failed {
                            Image(systemName: "photo")
                                .foregroundColor(.gray.opacity(0.45))
                        } else {
                            ProgressView().scaleEffect(0.65)
                        }
                    }
                }

                if item.mediaTotal > 1 {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                }

                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                        Text(Self.compact(item.likes ?? 0))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                        Spacer(minLength: 2)
                        Text(Self.date(item.postedAt))
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { loader.load(itemID: item.id, seq: 1, tier: .detail) }
    }

    private static func compact(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func date(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.component(.year, from: d) != cal.component(.year, from: Date()) {
            f.dateFormat = "MM-dd"
            return "去年 " + f.string(from: d)
        }
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 作品 BGM 播放器
//
// 抖音图文本质就是"图片轮播 + 音乐"，所以 feed 进入一条作品时要自动播它的 BGM。
// 关键点：
//   · 后端音频接口要 Bearer 头，AVPlayer 直接 init(url:) 发不出去。
//     AVURLAsset 也没有干净的自定义 header 注入点，所以走"带 token 下载到
//     临时文件 → AVPlayer 播本地文件"这条最稳的路。音频单首 0.5–2MB，
//     URLSession 磁盘缓存命中 ETag 后不重复流量。
//   · 全局只留一个播放器实例，滑走就 stop，不叠多个（内存/音频会话）。
//   · 循环播放：抖音 BGM 短则 20 秒，图集通常看更久，播完从头再来。
final class FeedMusicPlayer {
    static let shared = FeedMusicPlayer()

    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?
    private var currentItemID: Int?

    /// 当前是否在播（给转盘状态用）
    private(set) var isPlaying = false

    func play(itemID: Int) {
        guard let url = try? APIClient.shared.audioURL(itemID: itemID),
              let token = APIClient.bearerToken(), !token.isEmpty else { return }
        if currentItemID == itemID, player != nil, isPlaying { return }
        stop()

        // AVURLAsset 本身不支持自定义 header，iOS 通过 AVAssetResourceLoader
        // 也拿不到现成的注入点。最稳的做法：用 URLSession 带 token 下载音频字节，
        // 写成临时文件再交给 AVPlayer 播本地文件。
        // 后端音频文件带 ETag + Range，下载走磁盘缓存不重复流量。
        currentItemID = itemID
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard self.currentItemID == itemID else { return }  // 已经滑走了
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sw-bgm-\(itemID).mp3")
                try? data.write(to: tmp)
                let p = AVPlayer(url: tmp)
                p.volume = 0.7
                p.play()
                self.player = p
                self.isPlaying = true
                self.loopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                    queue: .main) { _ in
                        p.seek(to: .zero)
                        p.play()
                        self.isPlaying = true
                    }
            }
        }.resume()
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func stop() {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        player = nil
        currentItemID = nil
        isPlaying = false
    }

    /// 大图浏览器用：切到指定作品播放；已是当前则恢复暂停态。
    func playIfNeeded(itemID: Int) {
        if currentItemID == itemID {
            if !isPlaying { resume() }
        } else {
            play(itemID: itemID)
        }
    }

    /// 大图浏览器的播放/暂停按钮：当前作品在播则暂停，否则播放/恢复。
    func toggle(itemID: Int) {
        if currentItemID == itemID {
            if isPlaying { pause() } else { resume() }
        } else {
            play(itemID: itemID)
        }
    }

    /// 指定作品当前是否在播。
    func isPlaying(itemID: Int) -> Bool { currentItemID == itemID && isPlaying }
}

// MARK: - 抖音沉浸式浏览
//
// 一条作品占满一屏，上下滑动切换 —— 抖音 App 的浏览方式。
//
// 为什么用 UIKit 而不是 SwiftUI：
// iOS 16 的 TabView(.page) 只能水平翻页，没有 vertical 选项；
// 而本项目真机就是 iOS 16.1.1。垂直跟手翻页只有 UIPageViewController 原生支持。
// 另外之前 SwiftUI 的 sheet/TabView 嵌套反复出现整体偏移，这里沿用 UIKit
// 绝对布局，从根上避开那个坑。

struct DouyinFeedView: View {
    let items: [ArchiveItem]
    var initialIndex: Int = 0
    let hasMore: Bool
    let loadMore: () -> Void
    /// 返回个人主页宫格
    let onDismiss: (() -> Void)?
    /// 顶部搜索胶囊：返回宫格并聚焦搜索框
    let onSearch: (() -> Void)?

    private struct Selection: Identifiable {
        let id = UUID()
        let detail: ArchiveDetail
    }

    @State private var selection: Selection?

    var body: some View {
        ZStack {
            if items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载抖音内容…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                DouyinFeedPager(items: items,
                                initialIndex: initialIndex,
                                hasMore: hasMore,
                                loadMore: loadMore,
                                onOpen: { detail in selection = Selection(detail: detail) },
                                onDismiss: onDismiss,
                                onSearch: onSearch)
            }
        }
        // 点全屏图 → 复用已有的大图浏览器（原图 / 缩放 / 存相册 + BGM 继续播）
        .fullScreenCover(item: $selection) { sel in
            ImageViewer(media: sel.detail.media, startIndex: 0,
                        itemID: sel.detail.id, music: sel.detail.music)
        }
        // 离开抖音页（切到其他平台标签 / 退出内容库）就停 BGM
        .onDisappear { FeedMusicPlayer.shared.stop() }
    }
}

// MARK: - 垂直分页容器

private struct DouyinFeedPager: UIViewControllerRepresentable {
    let items: [ArchiveItem]
    let initialIndex: Int
    let hasMore: Bool
    let loadMore: () -> Void
    let onOpen: (ArchiveDetail) -> Void
    let onDismiss: (() -> Void)?
    let onSearch: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll,
                                         navigationOrientation: .vertical,
                                         options: nil)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black
        let idx = min(max(0, initialIndex), max(0, items.count - 1))
        pager.setViewControllers([context.coordinator.page(at: idx)],
                                 direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        // items 只会在「加载更多」时追加，不重建当前页，避免翻页中途跳位。
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DouyinFeedPager

        init(_ parent: DouyinFeedPager) { self.parent = parent }

        func page(at index: Int) -> UIViewController {
            let page = DouyinFeedPageVC()
            page.index = index
            page.item = parent.items[index]
            page.onOpen = { [weak self] detail in self?.parent.onOpen(detail) }
            page.onDismiss = { [weak self] in self?.parent.onDismiss?() }
            page.onSearch = { [weak self] in self?.parent.onSearch?() }
            return page
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let index = (vc as? DouyinFeedPageVC)?.index, index > 0 else { return nil }
            return page(at: index - 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let index = (vc as? DouyinFeedPageVC)?.index,
                  index + 1 < parent.items.count else { return nil }
            return page(at: index + 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let index = (pager.viewControllers?.first as? DouyinFeedPageVC)?.index else { return }
            // 快翻到底就自动补下一页，和抖音的无限流一致的观感
            if parent.hasMore, index >= parent.items.count - 2 {
                parent.loadMore()
            }
        }
    }
}

// MARK: - 单条作品全屏页

private final class DouyinFeedPageVC: UIViewController, UIGestureRecognizerDelegate {
    var index: Int = 0
    var item: ArchiveItem!
    var onOpen: ((ArchiveDetail) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearch: (() -> Void)?

    // 背景用 fill + 模糊，正文用 aspect-fit：和参考图一样完整展示竖图，
    // 两侧留黑但不突兀，不再把照片上下裁掉。
    private let bgImage = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let contentImage = UIImageView()
    private let shade = UIView()
    private let topShade = UIView()

    private let backButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)

    // 右侧互动栏：头像 / 赞 / 评论 / 收藏 / 分享
    private let railAvatar = UIImageView()
    private let likeIcon = UIImageView()
    private let likeCount = UILabel()
    private let commentIcon = UIImageView()
    private let commentCount = UILabel()
    private let favoriteIcon = UIImageView()
    private let favoriteCount = UILabel()
    private let shareIcon = UIImageView()
    private let shareCount = UILabel()
    private let likeHit = UIView()
    private let commentHit = UIView()
    private let favoriteHit = UIView()
    private let shareHit = UIView()
    /// 整页"点开大图"手势。委托里会避开所有控件区域，
    /// 免得点赞/收藏/返回时顺带把大图也打开。
    private let pageTap = UITapGestureRecognizer()
    private var liked = false
    private var favorited = false

    private let avatar = UIImageView()  // 兼容旧底部头像，现隐藏
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let metaLabel = UILabel()
    private let moreHint = UILabel()
    private let swipeHint = UILabel()

    // BGM 转盘：右下角旋转唱片 + 歌名/作者，点按暂停/继续
    private let discView = UIImageView()
    private let discRing = UIImageView()
    private let musicTitle = UILabel()
    private let musicAuthor = UILabel()
    private let musicNote = UILabel()
    private var discAnimation: CABasicAnimation?
    private var music: ArchiveMusic?

    private let imageLoader = ImageLoader()
    private let avatarLoader = ImageLoader()
    private var detail: ArchiveDetail?
    private var didLayout = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        loadDetail()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }
        let safeTop = view.safeAreaInsets.top
        let safeBottom = view.safeAreaInsets.bottom

        bgImage.frame = view.bounds
        blurView.frame = view.bounds
        contentImage.frame = view.bounds
        topShade.frame = CGRect(x: 0, y: 0, width: w, height: safeTop + 56)

        backButton.frame = CGRect(x: 12, y: safeTop + 6, width: 36, height: 36)
        searchButton.frame = CGRect(x: 56, y: safeTop + 6, width: max(0, w - 124), height: 36)
        swipeHint.frame = CGRect(x: 0, y: safeTop + 50, width: w, height: 18)

        let infoH: CGFloat = 278
        let infoTop = h - infoH
        shade.frame = CGRect(x: 0, y: infoTop, width: w, height: infoH)
        applyGradient()

        // 底部信息区自底向上分层，各占一行、绝不重叠：
        //   BGM 转盘/歌名 → 日期·张数 → 文案 → @昵称
        let bottomAnchor = h - safeBottom - 12
        let discSize: CGFloat = 42
        let discX = w - discSize - 16
        let discY = bottomAnchor - discSize
        discView.frame = CGRect(x: discX, y: discY, width: discSize, height: discSize)
        discRing.frame = CGRect(x: discView.frame.midX - 6, y: discView.frame.midY - 6,
                                width: 12, height: 12)
        discView.layer.cornerRadius = discSize / 2
        discRing.layer.cornerRadius = 6

        let musicW = discX - 18 - 12
        musicTitle.frame = CGRect(x: 18, y: discY + 3, width: musicW, height: 18)
        musicAuthor.frame = CGRect(x: 18, y: discY + 22, width: musicW, height: 15)
        musicNote.frame = .zero

        let metaY = discY - 8 - 18
        metaLabel.frame = CGRect(x: 18, y: metaY, width: w - 36, height: 18)

        let textW = w - 36
        textLabel.preferredMaxLayoutWidth = textW
        let textH = min(92, textLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
        let textY = metaY - 7 - textH
        textLabel.frame = CGRect(x: 18, y: textY, width: textW, height: textH)

        let nameY = textY - 8 - 24
        nameLabel.frame = CGRect(x: 18, y: nameY, width: w - 122, height: 24)
        moreHint.frame = CGRect(x: w - 108, y: nameY + 4, width: 90, height: 16)
        avatar.frame = .zero
        avatar.isHidden = true

        // 右侧竖排互动栏：先保证不被底部信息区盖住，再在小屏上整体抬高。
        let railX = w - 58
        let railTop = max(safeTop + 70, min(h * 0.34, infoTop - 270))
        railAvatar.frame = CGRect(x: railX - 1, y: railTop, width: 44, height: 44)
        railAvatar.layer.cornerRadius = 22
        let firstY = railTop + 62
        let step = max(48, (infoTop - firstY - 4) / 4)
        let railItems = [(likeIcon, likeCount, likeHit),
                         (commentIcon, commentCount, commentHit),
                         (favoriteIcon, favoriteCount, favoriteHit),
                         (shareIcon, shareCount, shareHit)]
        for (i, pair) in railItems.enumerated() {
            let y = firstY + CGFloat(i) * step
            pair.0.frame = CGRect(x: railX + 9, y: y, width: 26, height: 26)
            pair.1.frame = CGRect(x: railX - 6, y: y + 28, width: 56, height: 16)
            pair.2.frame = CGRect(x: railX - 8, y: y - 6, width: 60, height: 50)
        }
        didLayout = true
    }

    private func buildUI() {
        bgImage.contentMode = .scaleAspectFill
        bgImage.clipsToBounds = true
        bgImage.backgroundColor = UIColor(white: 0.06, alpha: 1)
        view.addSubview(bgImage)

        blurView.alpha = 0.82
        blurView.isUserInteractionEnabled = false
        view.addSubview(blurView)

        contentImage.contentMode = .scaleAspectFit
        contentImage.clipsToBounds = true
        contentImage.isUserInteractionEnabled = false
        view.addSubview(contentImage)

        topShade.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        topShade.isUserInteractionEnabled = false
        view.addSubview(topShade)

        shade.isUserInteractionEnabled = false
        view.addSubview(shade)

        // 顶部：返回 + 搜索胶囊（点搜索回到宫格并聚焦搜索框）
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        backButton.layer.cornerRadius = 18
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        view.addSubview(backButton)

        searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        searchButton.setTitle(" 搜你想看的", for: .normal)
        searchButton.titleLabel?.font = .systemFont(ofSize: 13)
        searchButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        searchButton.setTitleColor(UIColor.white.withAlphaComponent(0.85), for: .normal)
        searchButton.contentHorizontalAlignment = .left
        searchButton.backgroundColor = UIColor.white.withAlphaComponent(0.20)
        searchButton.layer.cornerRadius = 18
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        view.addSubview(searchButton)

        // 右侧头像 + 互动栏
        railAvatar.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        railAvatar.contentMode = .scaleAspectFill
        railAvatar.clipsToBounds = true
        railAvatar.layer.borderWidth = 1.5
        railAvatar.layer.borderColor = UIColor.white.cgColor
        view.addSubview(railAvatar)

        likeIcon.image = UIImage(systemName: "heart.fill")
        likeIcon.tintColor = .white
        likeIcon.contentMode = .scaleAspectFit
        view.addSubview(likeIcon)

        likeCount.font = .systemFont(ofSize: 11, weight: .medium)
        likeCount.textColor = .white
        likeCount.textAlignment = .center
        addShadow(likeCount)
        view.addSubview(likeCount)

        commentIcon.image = UIImage(systemName: "bubble.right.fill")
        commentIcon.tintColor = .white
        commentIcon.contentMode = .scaleAspectFit
        view.addSubview(commentIcon)

        commentCount.font = .systemFont(ofSize: 11, weight: .medium)
        commentCount.textColor = .white
        commentCount.textAlignment = .center
        addShadow(commentCount)
        view.addSubview(commentCount)

        favoriteIcon.image = UIImage(systemName: "star.fill")
        favoriteIcon.tintColor = .white
        favoriteIcon.contentMode = .scaleAspectFit
        view.addSubview(favoriteIcon)

        favoriteCount.font = .systemFont(ofSize: 11, weight: .medium)
        favoriteCount.textColor = .white
        favoriteCount.textAlignment = .center
        favoriteCount.text = "收藏"
        addShadow(favoriteCount)
        view.addSubview(favoriteCount)

        shareIcon.image = UIImage(systemName: "arrowshape.turn.up.right.fill")
        shareIcon.tintColor = .white
        shareIcon.contentMode = .scaleAspectFit
        view.addSubview(shareIcon)

        shareCount.font = .systemFont(ofSize: 11, weight: .medium)
        shareCount.textColor = .white
        shareCount.textAlignment = .center
        shareCount.text = "分享"
        addShadow(shareCount)
        view.addSubview(shareCount)

        likeHit.backgroundColor = .clear
        commentHit.backgroundColor = .clear
        favoriteHit.backgroundColor = .clear
        shareHit.backgroundColor = .clear
        view.addSubview(likeHit)
        view.addSubview(commentHit)
        view.addSubview(favoriteHit)
        view.addSubview(shareHit)
        likeHit.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleLike)))
        favoriteHit.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleFavorite)))
        shareHit.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shareTapped)))

        // 底部文案
        avatar.isHidden = true
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        addShadow(nameLabel)
        view.addSubview(nameLabel)

        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = .white
        textLabel.numberOfLines = 4
        textLabel.lineBreakMode = .byTruncatingTail
        addShadow(textLabel)
        view.addSubview(textLabel)

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        addShadow(metaLabel)
        view.addSubview(metaLabel)

        moreHint.font = .systemFont(ofSize: 11)
        moreHint.textColor = UIColor.white.withAlphaComponent(0.72)
        moreHint.textAlignment = .right
        moreHint.text = "展开 ∨"
        addShadow(moreHint)
        view.addSubview(moreHint)

        swipeHint.text = "上下滑动切换作品"
        swipeHint.font = .systemFont(ofSize: 11)
        swipeHint.textColor = UIColor.white.withAlphaComponent(0.6)
        swipeHint.textAlignment = .center
        view.addSubview(swipeHint)
        // 3 秒后淡出，避免长期占据画面
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            UIView.animate(withDuration: 0.5) { self?.swipeHint.alpha = 0 }
        }

        // BGM 转盘：唱片底图 + 中心孔，歌名/作者横排在左侧
        discView.contentMode = .scaleAspectFill
        discView.clipsToBounds = true
        discView.isHidden = true
        discView.backgroundColor = UIColor(white: 0.15, alpha: 0.9)
        discView.layer.borderColor = UIColor(white: 0.85, alpha: 0.9).cgColor
        discView.layer.borderWidth = 2
        view.addSubview(discView)

        discRing.isHidden = true
        discRing.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        discRing.layer.borderColor = UIColor.white.cgColor
        discRing.layer.borderWidth = 1
        view.addSubview(discRing)

        musicTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        musicTitle.textColor = .white
        musicTitle.numberOfLines = 1
        musicTitle.isHidden = true
        addShadow(musicTitle)
        view.addSubview(musicTitle)

        musicAuthor.font = .systemFont(ofSize: 10)
        musicAuthor.textColor = UIColor.white.withAlphaComponent(0.75)
        musicAuthor.numberOfLines = 1
        musicAuthor.isHidden = true
        addShadow(musicAuthor)
        view.addSubview(musicAuthor)

        // 转盘自己的点击手势（暂停/继续），要优先于整页的"点开大图"
        let discTap = UITapGestureRecognizer(target: self, action: #selector(toggleMusic))
        discTap.cancelsTouchesInView = true
        discView.addGestureRecognizer(discTap)
        discView.isUserInteractionEnabled = true

        pageTap.addTarget(self, action: #selector(openFullscreen))
        pageTap.delegate = self
        pageTap.cancelsTouchesInView = true
        view.addGestureRecognizer(pageTap)
    }

    private func applyGradient() {
        shade.layer.sublayers?.removeAll(where: { $0 is CAGradientLayer })
        let g = CAGradientLayer()
        g.frame = shade.bounds
        g.colors = [UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.35).cgColor,
                    UIColor.black.withAlphaComponent(0.88).cgColor]
        g.locations = [0, 0.45, 1]
        shade.layer.insertSublayer(g, at: 0)
    }

    private func addShadow(_ label: UILabel) {
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    private func loadDetail() {
        let id = item.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let d = try await APIClient.shared.archiveItem(id: id)
                guard self.isViewLoaded, self.view.window != nil else { return }
                self.detail = d
                self.apply(detail: d)
                if let first = d.media.first {
                    self.imageLoader.onImage = { [weak self] img in
                        guard let self else { return }
                        // 背景铺满 + 模糊，正文完整显示，不出裁切也不出白边。
                        self.bgImage.image = img
                        self.contentImage.image = img
                    }
                    self.imageLoader.load(itemID: d.id, seq: first.seq, tier: .detail)
                }
                if let url = d.authorAvatar, !url.isEmpty {
                    self.avatarLoader.onImage = { [weak self] img in self?.railAvatar.image = img }
                    self.avatarLoader.load(remoteURL: url)
                }
            } catch {
                // 详情失败不影响翻页，文案退化为列表里已有的信息
                self.nameLabel.text = "@抖音用户"
                self.textLabel.text = self.item.cleanText
                self.metaLabel.text = self.meta(from: self.item)
                self.railAvatar.image = Self.placeholder(letter: "抖")
            }
        }
    }

    private func apply(detail d: ArchiveDetail) {
        nameLabel.text = "@\(d.authorName ?? "抖音用户")  ·  图文"
        textLabel.text = d.cleanText.isEmpty ? "（无正文）" : d.cleanText
        metaLabel.text = "\(postDateText(d.postedAt))  ·  \(d.media.count) 张图"
        likeCount.text = shortNumber(max(0, d.likes ?? 0) + (liked ? 1 : 0))
        commentCount.text = shortNumber(d.commentsCount ?? 0)
        if railAvatar.image == nil {
            railAvatar.image = Self.placeholder(letter: d.authorName ?? "抖")
        }
        if didLayout { view.setNeedsLayout() }

        // BGM：有播放地址就自动播 + 转盘转起来；没有直链也显示歌名（信息不丢）
        if let m = d.music, !(m.title ?? "").isEmpty {
            self.music = m
            musicTitle.text = "♫ \(m.displayTitle)"
            musicAuthor.text = m.displayAuthor
            musicTitle.isHidden = false
            musicAuthor.isHidden = false
            discView.isHidden = false
            discRing.isHidden = false
            // 封面图作唱片纹路
            if let url = m.coverURL, !url.isEmpty {
                avatarLoader.onImage = nil  // 头像已加载完，复用会覆盖
                let coverLoader = ImageLoader()
                coverLoader.onImage = { [weak self] img in self?.discView.image = img }
                coverLoader.load(remoteURL: url)
                objc_setAssociatedObject(self, &Self.coverLoaderKey, coverLoader,
                                         .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                discView.image = Self.placeholder(letter: m.displayTitle)
            }
            FeedMusicPlayer.shared.play(itemID: d.id)
            startDiscAnimation()
            #if DEBUG
            // 自动化验证：详情加载完自动打开首图，验证"图片+音乐"大图条
            if ProcessInfo.processInfo.environment["SW_DEBUG_OPENIMAGE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.onOpen?(d)
                }
            }
            #endif
        }
    }

    private static var coverLoaderKey: UInt8 = 0

    private func startDiscAnimation() {
        discView.layer.removeAnimation(forKey: "disc")
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.toValue = NSNumber(value: Double.pi * 2)
        a.duration = 4
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        discView.layer.add(a, forKey: "disc")
        discAnimation = a
    }

    private func stopDiscAnimation() {
        discView.layer.removeAnimation(forKey: "disc")
        discAnimation = nil
    }

    @objc private func toggleMusic() {
        guard music != nil else { return }
        let player = FeedMusicPlayer.shared
        if player.isPlaying {
            player.pause()
            stopDiscAnimation()
        } else {
            player.resume()
            startDiscAnimation()
        }
    }

    @objc private func backTapped() { onDismiss?() }

    @objc private func searchTapped() { onSearch?() }

    @objc private func toggleLike() {
        guard detail != nil else { return }
        liked.toggle()
        likeIcon.tintColor = liked ? UIColor(red: 1, green: 0.28, blue: 0.36, alpha: 1) : .white
        likeCount.text = shortNumber(max(0, detail?.likes ?? 0) + (liked ? 1 : 0))
    }

    @objc private func toggleFavorite() {
        guard detail != nil else { return }
        favorited.toggle()
        favoriteIcon.tintColor = favorited ? UIColor(red: 1, green: 0.78, blue: 0.15, alpha: 1) : .white
    }

    @objc private func shareTapped() {
        guard let d = detail else { return }
        var items: [Any] = [d.cleanText]
        if let url = d.url, !url.isEmpty { items.append(url) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(vc, animated: true)
    }

    /// 只让点在"图片本身"上的手势打开大图；按钮/互动栏区域不误触。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pageTap else { return true }
        let p = gestureRecognizer.location(in: view)
        guard let hit = view.hitTest(p, with: nil) else { return true }
        return hit === view || hit === contentImage || hit === bgImage
            || hit === shade || hit === topShade
    }

    private func meta(from item: ArchiveItem) -> String {
        "\(dateText(item.postedAt))  ·  \(item.mediaTotal) 张图"
    }

    @objc private func openFullscreen() {
        guard let detail else { return }
        onOpen?(detail)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        swipeHint.alpha = 0
        // 滑走就停歌，下一页会播自己的 BGM；不留多个播放器叠着
        FeedMusicPlayer.shared.stop()
        stopDiscAnimation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 从大图浏览器返回时，若音乐被停了就恢复（同一条作品）
        if let d = detail, let m = d.music, !(m.title ?? "").isEmpty,
           !FeedMusicPlayer.shared.isPlaying {
            FeedMusicPlayer.shared.play(itemID: d.id)
            startDiscAnimation()
        }
    }

    private func dateText(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// 参考图的日期样式：今年显示「M月d日」，跨年带年份。
    private func postDateText(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.component(.year, from: d)
            == Calendar.current.component(.year, from: Date())
            ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    private func shortNumber(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func placeholder(letter: String) -> UIImage {
        let size = CGSize(width: 68, height: 68)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.32, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .medium),
                .foregroundColor: UIColor.white
            ]
            let s = String(letter.prefix(1))
            let str = NSAttributedString(string: s, attributes: attrs)
            let r = CGRect(x: (size.width - str.size().width) / 2,
                           y: (size.height - str.size().height) / 2,
                           width: str.size().width, height: str.size().height)
            str.draw(in: r)
        }
    }
}
