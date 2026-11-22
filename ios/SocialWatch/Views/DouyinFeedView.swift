import SwiftUI
import UIKit

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
    let hasMore: Bool
    let loadMore: () -> Void

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
                DouyinFeedPager(items: items, hasMore: hasMore, loadMore: loadMore) { detail in
                    selection = Selection(detail: detail)
                }
            }
        }
        // 点全屏图 → 复用已有的大图浏览器（原图 / 缩放 / 存相册）
        .fullScreenCover(item: $selection) { sel in
            ImageViewer(media: sel.detail.media, startIndex: 0, itemID: sel.detail.id)
        }
    }
}

// MARK: - 垂直分页容器

private struct DouyinFeedPager: UIViewControllerRepresentable {
    let items: [ArchiveItem]
    let hasMore: Bool
    let loadMore: () -> Void
    let onOpen: (ArchiveDetail) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll,
                                         navigationOrientation: .vertical,
                                         options: nil)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black
        pager.setViewControllers([context.coordinator.page(at: 0)],
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

private final class DouyinFeedPageVC: UIViewController {
    var index: Int = 0
    var item: ArchiveItem!
    var onOpen: ((ArchiveDetail) -> Void)?

    private let bgImage = UIImageView()
    private let shade = UIView()
    private let topShade = UIView()
    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let metaLabel = UILabel()
    private let likeIcon = UIImageView()
    private let likeCount = UILabel()
    private let commentIcon = UIImageView()
    private let commentCount = UILabel()
    private let moreHint = UILabel()
    private let swipeHint = UILabel()

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
        bgImage.frame = view.bounds
        topShade.frame = CGRect(x: 0, y: 0, width: w, height: 110)

        let infoH: CGFloat = 250
        shade.frame = CGRect(x: 0, y: h - infoH, width: w, height: infoH)
        applyGradient()

        let safeBottom = view.safeAreaInsets.bottom
        let metaY = h - safeBottom - 22 - 18
        metaLabel.frame = CGRect(x: 18, y: metaY, width: w - 110, height: 18)

        // 文案最多 4 行；用 sizeThatFits 量出真实高度，让昵称行贴着文案上方
        let textW = w - 36
        textLabel.preferredMaxLayoutWidth = textW
        let textH = min(96, textLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
        let textY = metaY - 10 - textH
        textLabel.frame = CGRect(x: 18, y: textY, width: textW, height: textH)

        let nameY = textY - 10 - 34
        avatar.frame = CGRect(x: 18, y: nameY, width: 34, height: 34)
        avatar.layer.cornerRadius = 17
        nameLabel.frame = CGRect(x: 60, y: nameY, width: w - 130, height: 34)

        // 右侧互动栏，竖排在文案区上方
        let actionX = w - 60
        let actionBaseY = textY - 18
        likeIcon.frame = CGRect(x: actionX + 8, y: actionBaseY - 106, width: 26, height: 26)
        likeCount.frame = CGRect(x: actionX, y: actionBaseY - 78, width: 42, height: 18)
        commentIcon.frame = CGRect(x: actionX + 8, y: actionBaseY - 46, width: 26, height: 26)
        commentCount.frame = CGRect(x: actionX, y: actionBaseY - 18, width: 42, height: 18)
        moreHint.frame = CGRect(x: actionX - 26, y: actionBaseY + 8, width: 94, height: 18)

        swipeHint.frame = CGRect(x: 0, y: 62, width: w, height: 20)
        didLayout = true
    }

    private func buildUI() {
        bgImage.contentMode = .scaleAspectFill
        bgImage.clipsToBounds = true
        bgImage.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.addSubview(bgImage)

        topShade.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        view.addSubview(topShade)

        shade.isUserInteractionEnabled = false
        view.addSubview(shade)

        avatar.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.borderWidth = 1
        avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        view.addSubview(avatar)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        addShadow(nameLabel)
        view.addSubview(nameLabel)

        textLabel.font = .systemFont(ofSize: 15)
        textLabel.textColor = .white
        textLabel.numberOfLines = 4
        textLabel.lineBreakMode = .byTruncatingTail
        addShadow(textLabel)
        view.addSubview(textLabel)

        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        addShadow(metaLabel)
        view.addSubview(metaLabel)

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

        moreHint.font = .systemFont(ofSize: 11)
        moreHint.textColor = UIColor.white.withAlphaComponent(0.72)
        moreHint.textAlignment = .center
        moreHint.text = "点按看全部"
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(openFullscreen))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
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
                        self.bgImage.image = img
                    }
                    self.imageLoader.load(itemID: d.id, seq: first.seq, tier: .detail)
                }
                if let url = d.authorAvatar, !url.isEmpty {
                    self.avatarLoader.onImage = { [weak self] img in self?.avatar.image = img }
                    self.avatarLoader.load(remoteURL: url)
                }
            } catch {
                // 详情失败不影响翻页，文案退化为列表里已有的信息
                self.nameLabel.text = "@抖音用户"
                self.textLabel.text = self.item.cleanText
                self.metaLabel.text = self.meta(from: self.item)
            }
        }
    }

    private func apply(detail d: ArchiveDetail) {
        nameLabel.text = "@\(d.authorName ?? "抖音用户")"
        textLabel.text = d.cleanText.isEmpty ? "（无正文）" : d.cleanText
        metaLabel.text = "\(dateText(d.postedAt))  ·  \(d.media.count) 张图"
        likeCount.text = shortNumber(d.likes ?? 0)
        commentCount.text = shortNumber(d.commentsCount ?? 0)
        if avatar.image == nil {
            avatar.image = Self.placeholder(letter: d.authorName ?? "抖")
        }
        if didLayout { view.setNeedsLayout() }
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
    }

    private func dateText(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
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
