import SwiftUI
import UIKit
import AVFoundation

// MARK: - SwiftUI 入口
//
// 这是一个独立于旧归档列表的抖音模块：
//   1. 个人主页式作品宫格
//   2. 全屏作品播放器（上下切作品、作品内左右切图、BGM 连续）
// 外层内容库壳在 ArchiveListView 里按抖音页隐藏。

struct DouyinCloneView: View {
    let items: [ArchiveItem]
    let hasMore: Bool
    let loadMore: () -> Void
    let onExit: () -> Void

    private struct PlayerSelection: Identifiable {
        let id = UUID()
        let index: Int
        let items: [ArchiveItem]
    }

    @State private var playerSelection: PlayerSelection?
    #if DEBUG
    @State private var didAutoOpen = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("正在加载抖音作品…")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if DEBUG
                if ProcessInfo.processInfo.environment["SW_DEBUG_CLONE_PLAYER_ONLY"] == "1" {
                    DouyinPlayerHost(
                        items: items,
                        initialIndex: 0,
                        hasMore: hasMore,
                        loadMore: loadMore,
                        onDismiss: onExit,
                        onSearch: onExit
                    )
                    .ignoresSafeArea()
                } else {
                    DouyinProfileHost(
                        items: items,
                        hasMore: hasMore,
                        loadMore: loadMore,
                        onOpen: { displayed, index in
                            playerSelection = PlayerSelection(index: index, items: displayed)
                        },
                        onExit: onExit
                    )
                    .ignoresSafeArea()
                }
                #else
                DouyinProfileHost(
                    items: items,
                    hasMore: hasMore,
                    loadMore: loadMore,
                    onOpen: { displayed, index in
                        playerSelection = PlayerSelection(index: index, items: displayed)
                    },
                    onExit: onExit
                )
                .ignoresSafeArea()
                #endif
            }
        }
        .fullScreenCover(item: $playerSelection) { selection in
            DouyinPlayerHost(
                items: selection.items,
                initialIndex: selection.index,
                hasMore: hasMore,
                loadMore: loadMore,
                onDismiss: { playerSelection = nil },
                onSearch: { playerSelection = nil }
            )
            .ignoresSafeArea()
        }
        .onDisappear { FeedMusicPlayer.shared.stop() }
        #if DEBUG
        .onAppear { autoOpenIfNeeded() }
        .onChange(of: items.count) { _ in autoOpenIfNeeded() }
        #endif
    }

    #if DEBUG
    private func autoOpenIfNeeded() {
        guard !didAutoOpen, !items.isEmpty,
              ProcessInfo.processInfo.environment["SW_DEBUG_CLONE_OPEN"] == "1" else { return }
        didAutoOpen = true
        playerSelection = PlayerSelection(index: 0, items: items)
    }
    #endif
}

// MARK: - 个人主页 UIKit 承载

private struct DouyinProfileHost: UIViewControllerRepresentable {
    let items: [ArchiveItem]
    let hasMore: Bool
    let loadMore: () -> Void
    let onOpen: ([ArchiveItem], Int) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> DouyinProfileVC {
        let vc = DouyinProfileVC()
        vc.apply(items: items, hasMore: hasMore, loadMore: loadMore)
        vc.onOpen = onOpen
        vc.onExit = onExit
        return vc
    }

    func updateUIViewController(_ vc: DouyinProfileVC, context: Context) {
        vc.apply(items: items, hasMore: hasMore, loadMore: loadMore)
        vc.onOpen = onOpen
        vc.onExit = onExit
    }

    final class Coordinator {}
}

private final class DouyinProfileVC: UIViewController,
                                     UICollectionViewDataSource,
                                     UICollectionViewDelegateFlowLayout {
    var items: [ArchiveItem] = []
    var hasMore: Bool = false
    var loadMore: (() -> Void)?
    var onOpen: (([ArchiveItem], Int) -> Void)?
    var onExit: (() -> Void)?

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 2
        layout.minimumInteritemSpacing = 2
        layout.sectionInset = UIEdgeInsets(top: 2, left: 2, bottom: 24, right: 2)
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    private var displayed: [ArchiveItem] = []
    private var query = ""
    private var detail: ArchiveDetail?
    private let coverLoader = ImageLoader()
    private let avatarLoader = ImageLoader()
    private weak var currentHeader: DouyinProfileHeaderView?
    private var didRequestDetail = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(DouyinWorkCell.self, forCellWithReuseIdentifier: "work")
        collectionView.register(
            DouyinProfileHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "profileHeader"
        )
        view.addSubview(collectionView)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.frame = view.bounds

        loadDetailIfNeeded()
    }

    func apply(items newItems: [ArchiveItem], hasMore newHasMore: Bool, loadMore newLoadMore: @escaping () -> Void) {
        let countChanged = newItems.count != items.count
        items = newItems
        hasMore = newHasMore
        loadMore = newLoadMore
        rebuildDisplayed(reload: countChanged || collectionView.numberOfItems(inSection: 0) == 0)
        loadDetailIfNeeded()
    }

    private func rebuildDisplayed(reload: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            displayed = items
        } else {
            displayed = items.filter { $0.cleanText.localizedCaseInsensitiveContains(q) }
        }
        if reload { collectionView.reloadData() }
    }

    private func loadDetailIfNeeded() {
        guard !didRequestDetail, let first = items.first else { return }
        didRequestDetail = true
        let id = first.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let d = try? await APIClient.shared.archiveItem(id: id) else { return }
            self.detail = d
            self.currentHeader?.configure(
                detail: d,
                items: self.items,
                query: self.query,
                onBack: { [weak self] in self?.onExit?() },
                onShare: { [weak self] in self?.shareProfile() },
                onSearch: { [weak self] text in
                    guard let self else { return }
                    self.query = text
                    self.rebuildDisplayed(reload: true)
                }
            )
            if let media = d.media.first {
                self.coverLoader.onImage = { [weak self] image in
                    self?.currentHeader?.coverImageView.image = image
                }
                self.coverLoader.load(itemID: d.id, seq: media.seq, tier: .detail)
            }
            if let url = d.authorAvatar, !url.isEmpty {
                self.avatarLoader.onImage = { [weak self] image in
                    self?.currentHeader?.avatarImageView.image = image
                }
                self.avatarLoader.load(remoteURL: url)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["SW_DEBUG_CLONE_OPEN"] == "1" {
                self.onOpen?(self.items, 0)
            }
            #endif
        }
    }

    private func shareProfile() {
        var text = detail?.authorName ?? items.first?.authorName ?? "抖音创作者"
        if let url = items.first?.url, !url.isEmpty { text += "\n\(url)" }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        present(vc, animated: true)
    }

    // MARK: UICollectionView

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayed.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "work", for: indexPath)
        guard let workCell = cell as? DouyinWorkCell else { return cell }
        workCell.configure(item: displayed[indexPath.item])
        return workCell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onOpen?(displayed, indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let side = max(80, floor((collectionView.bounds.width - 8) / 3))
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: DouyinProfileHeaderView.headerHeight(in: self))
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                  ofKind: kind,
                  withReuseIdentifier: "profileHeader",
                  for: indexPath
              ) as? DouyinProfileHeaderView else {
            return UICollectionReusableView()
        }
        currentHeader = header
        header.configure(
            detail: detail,
            items: items,
            query: query,
            onBack: { [weak self] in self?.onExit?() },
            onShare: { [weak self] in self?.shareProfile() },
            onSearch: { [weak self] text in
                guard let self else { return }
                self.query = text
                self.rebuildDisplayed(reload: true)
            }
        )
        return header
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasMore else { return }
        let threshold = scrollView.contentSize.height - scrollView.bounds.height - 320
        if scrollView.contentOffset.y >= threshold {
            loadMore?()
            hasMore = false
        }
    }
}

// MARK: - 个人主页 Header

private final class DouyinProfileHeaderView: UICollectionReusableView, UITextFieldDelegate {
    let coverImageView = UIImageView()
    private let dimView = UIView()
    private let sheetView = UIView()

    let avatarImageView = UIImageView()
    private let nameLabel = UILabel()
    private let idLabel = UILabel()

    private let statValues = [UILabel(), UILabel(), UILabel()]
    private let statLabels = [UILabel(), UILabel(), UILabel()]

    private let signatureLabel = UILabel()
    private let shareButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let dateButton = UIButton(type: .system)
    private let tabs = [UILabel(), UILabel()]

    private var onBack: (() -> Void)?
    private var onShare: (() -> Void)?
    private var onSearch: ((String) -> Void)?

    private static func stat(_ value: String, label: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: value, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: UIColor.white
        ]))
        s.append(NSAttributedString(string: " " + label, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62)
        ]))
        return s
    }

    private static func tab(_ title: String, selected: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title + "  ", attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? UIColor.white : UIColor.white.withAlphaComponent(0.55)
        ])
        s.append(NSAttributedString(string: "▾", attributes: [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: selected ? UIColor.white : UIColor.white.withAlphaComponent(0.55)
        ]))
        return s
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func headerHeight(in vc: UIViewController) -> CGFloat {
        (vc.view.window?.safeAreaInsets.top ?? vc.view.safeAreaInsets.top) + 410
    }

    private func buildUI() {
        backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
        clipsToBounds = true

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        addSubview(coverImageView)

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        addSubview(dimView)

        sheetView.backgroundColor = UIColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1)
        sheetView.layer.cornerRadius = 18
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(sheetView)

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backButton.layer.cornerRadius = 17
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        addSubview(backButton)

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareButton.tintColor = .white
        shareButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        shareButton.layer.cornerRadius = 17
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        addSubview(shareButton)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 36
        avatarImageView.layer.borderWidth = 1.5
        avatarImageView.layer.borderColor = UIColor.white.cgColor
        avatarImageView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        addSubview(avatarImageView)

        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.text = "抖音创作者"
        addSubview(nameLabel)

        idLabel.font = .systemFont(ofSize: 12)
        idLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        idLabel.text = "抖音号：已归档账号"
        addSubview(idLabel)

        // 真实抖音个人页：数值 + 标签同一行（如「1986.8万 获赞」），
        // 数值加粗白色、标签灰色小字，整组居中。
        for i in 0..<3 {
            statValues[i].textAlignment = .center
            statValues[i].attributedText = Self.stat("—", label: ["获赞", "关注", "粉丝"][i])
            addSubview(statValues[i])
        }

        signatureLabel.font = .systemFont(ofSize: 13)
        signatureLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        signatureLabel.numberOfLines = 1
        signatureLabel.text = "已归档图文与音乐作品"
        addSubview(signatureLabel)

        for label in tabs {
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.6)
            label.textAlignment = .center
            addSubview(label)
        }
        tabs[0].textColor = .white

        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.placeholder = "搜索 Ta 的作品"
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = .white
        searchField.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        searchField.layer.cornerRadius = 17
        searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        searchField.leftViewMode = .always
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        addSubview(searchField)

        dateButton.setTitle("日期筛选", for: .normal)
        dateButton.titleLabel?.font = .systemFont(ofSize: 12)
        dateButton.setTitleColor(UIColor.white.withAlphaComponent(0.72), for: .normal)
        dateButton.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        dateButton.layer.cornerRadius = 15
        dateButton.isUserInteractionEnabled = false
        addSubview(dateButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0 else { return }
        let safeTop = window?.safeAreaInsets.top ?? safeAreaInsets.top

        coverImageView.frame = CGRect(x: 0, y: 0, width: w, height: safeTop + 230)
        dimView.frame = coverImageView.frame
        sheetView.frame = CGRect(x: 0, y: safeTop + 178, width: w, height: bounds.height - safeTop - 178)

        backButton.frame = CGRect(x: 12, y: safeTop + 8, width: 34, height: 34)
        shareButton.frame = CGRect(x: w - 46, y: safeTop + 8, width: 34, height: 34)
        avatarImageView.frame = CGRect(x: 16, y: safeTop + 72, width: 72, height: 72)
        nameLabel.frame = CGRect(x: 100, y: safeTop + 74, width: w - 116, height: 24)
        idLabel.frame = CGRect(x: 100, y: safeTop + 103, width: w - 116, height: 18)

        let statY = safeTop + 192
        let colW = w / 3
        for i in 0..<3 {
            statValues[i].frame = CGRect(x: CGFloat(i) * colW, y: statY, width: colW, height: 24)
        }

        signatureLabel.frame = CGRect(x: 16, y: safeTop + 244, width: w - 32, height: 18)
        tabs[0].frame = CGRect(x: 0, y: safeTop + 284, width: w / 2, height: 40)
        tabs[1].frame = CGRect(x: w / 2, y: safeTop + 284, width: w / 2, height: 40)

        searchField.frame = CGRect(x: 16, y: safeTop + 334, width: w - 94, height: 34)
        dateButton.frame = CGRect(x: w - 70, y: safeTop + 334, width: 54, height: 34)
    }

    func configure(detail: ArchiveDetail?,
                   items: [ArchiveItem],
                   query: String,
                   onBack: @escaping () -> Void,
                   onShare: @escaping () -> Void,
                   onSearch: @escaping (String) -> Void) {
        self.onBack = onBack
        self.onShare = onShare
        self.onSearch = onSearch
        if searchField.text != query { searchField.text = query }

        let author = detail?.authorName ?? items.first?.authorName ?? "抖音创作者"
        nameLabel.text = author
        if let id = detail?.douyinID, !id.isEmpty {
            idLabel.text = "抖音号：\(id)"
        } else if let key = detail?.targetKey ?? items.first?.targetKey, key.contains(":") {
            let raw = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            idLabel.text = "抖音号：\(String(raw.prefix(12)))\(raw.count > 12 ? "…" : "")"
        }
        signatureLabel.text = detail?.signature ?? "已归档图文与音乐作品"

        let totalLikes = items.reduce(0) { $0 + max(0, $1.likes ?? 0) }
        let values = [swNumber(detail?.playCount ?? totalLikes),
                      detail?.followingCount.map(swNumber) ?? "—",
                      detail?.followerCount.map(swNumber) ?? "—"]
        let labels = ["获赞", "关注", "粉丝"]
        for i in 0..<3 {
            statValues[i].attributedText = Self.stat(values[i], label: labels[i])
        }

        let works = items.count
        tabs[0].attributedText = Self.tab("作品 \(works)", selected: true)
        tabs[1].attributedText = Self.tab("图文 \(items.filter { $0.mediaTotal > 1 }.count)", selected: false)
        if avatarImageView.image == nil {
            avatarImageView.image = Self.placeholder(letter: author)
        }
    }

    @objc private func backTapped() { onBack?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func searchChanged() { onSearch?(searchField.text ?? "") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private static func placeholder(letter: String) -> UIImage {
        let size = CGSize(width: 72, height: 72)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.22, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let text = String(letter.prefix(1)) as NSString
            let font = UIFont.systemFont(ofSize: 30, weight: .semibold)
            let rect = text.boundingRect(
                with: size,
                options: .usesLineFragmentOrigin,
                attributes: [.font: font],
                context: nil
            )
            text.draw(in: CGRect(x: (size.width - rect.width) / 2,
                                 y: (size.height - rect.height) / 2,
                                 width: rect.width,
                                 height: rect.height),
                      withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
}

// MARK: - 宫格 cell

private final class DouyinWorkCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let tagLabel = UILabel()
    private let countLabel = UILabel()
    private let shade = UIView()
    private var loader = ImageLoader()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.10, alpha: 1)
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        shade.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        contentView.addSubview(shade)

        tagLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        tagLabel.textColor = UIColor(red: 1, green: 0.83, blue: 0.18, alpha: 1)
        tagLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        tagLabel.textAlignment = .center
        tagLabel.layer.cornerRadius = 3
        tagLabel.clipsToBounds = true
        contentView.addSubview(tagLabel)

        countLabel.font = .systemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .white
        countLabel.layer.shadowColor = UIColor.black.cgColor
        countLabel.layer.shadowOpacity = 0.8
        countLabel.layer.shadowRadius = 2
        contentView.addSubview(countLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
        shade.frame = CGRect(x: 0, y: bounds.height - 34, width: bounds.width, height: 34)
        let tagW = min(bounds.width - 10, 58)
        tagLabel.frame = CGRect(x: bounds.width - tagW - 5, y: 5, width: tagW, height: 16)
        countLabel.frame = CGRect(x: 6, y: bounds.height - 22, width: bounds.width - 12, height: 16)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        tagLabel.text = nil
        countLabel.text = nil
        loader.onImage = nil
        loader = ImageLoader()
    }

    func configure(item: ArchiveItem) {
        if item.mediaTotal > 1 {
            tagLabel.text = "图文 \(item.mediaTotal)"
        } else if item.video == true {
            tagLabel.text = "视频"
        } else {
            tagLabel.text = nil
        }
        if let play = item.playCount {
            countLabel.text = "▶ \(swNumber(play))"
        } else if let likes = item.likes {
            countLabel.text = "♥ \(swNumber(likes))"
        } else {
            countLabel.text = nil
        }
        loader.onImage = { [weak self] image in self?.imageView.image = image }
        loader.load(itemID: item.id, seq: 1, tier: .detail)
    }
}

// MARK: - 播放页 SwiftUI 承载

private struct DouyinPlayerHost: UIViewControllerRepresentable {
    let items: [ArchiveItem]
    let initialIndex: Int
    let hasMore: Bool
    let loadMore: () -> Void
    let onDismiss: () -> Void
    let onSearch: () -> Void

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
                                 direction: .forward,
                                 animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DouyinPlayerHost

        init(_ parent: DouyinPlayerHost) { self.parent = parent }

        func page(at index: Int) -> UIViewController {
            let page = DouyinPlayerPageVC()
            page.index = index
            page.item = parent.items[index]
            page.onDismiss = { [weak self] in self?.parent.onDismiss() }
            page.onSearch = { [weak self] in self?.parent.onSearch() }
            return page
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let page = vc as? DouyinPlayerPageVC, page.index > 0 else { return nil }
            return self.page(at: page.index - 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let page = vc as? DouyinPlayerPageVC,
                  page.index + 1 < parent.items.count else { return nil }
            return self.page(at: page.index + 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let page = pager.viewControllers?.first as? DouyinPlayerPageVC else { return }
            if parent.hasMore, page.index >= parent.items.count - 2 {
                parent.loadMore()
            }
        }
    }
}

// MARK: - 单条作品播放页

private final class DouyinPlayerPageVC: UIViewController,
                                        UIScrollViewDelegate,
                                        UIGestureRecognizerDelegate {
    var index: Int = 0
    var item: ArchiveItem!
    var onDismiss: (() -> Void)?
    var onSearch: (() -> Void)?

    private let backgroundImageView = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let mediaScrollView = UIScrollView()
    private var mediaViews: [UIImageView] = []
    private var mediaLoaders: [ImageLoader] = []
    private var currentMediaIndex = 0

    private let topShade = UIView()
    private let bottomShade = UIView()
    private let backButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)

    private let railAvatar = UIImageView()
    private let followBadge = UILabel()
    private let likeIcon = UIImageView()
    private let likeCount = UILabel()
    private let commentIcon = UIImageView()
    private let commentCount = UILabel()
    private let favoriteIcon = UIImageView()
    private let favoriteCount = UILabel()
    private let shareIcon = UIImageView()
    private let shareCount = UILabel()
    private let discView = UIImageView()
    private let discHole = UIView()

    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let musicLabel = UILabel()
    private let pageBars = UIStackView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let likeBurst = UIImageView()

    // 底部抖音 TabBar（首页 / 朋友 / + / 消息 / 我）
    private let bottomTabBar = UIView()
    private var tabButtons: [UIButton] = []
    private let plusButton = UIButton(type: .system)

    private let avatarLoader = ImageLoader()
    private let discCoverLoader = ImageLoader()
    private var detail: ArchiveDetail?
    private var liked = false
    private var favorited = false
    private var followed = false
    private var progressTimer: Timer?
    private var discAnimation: CABasicAnimation?

    private let singleTap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private var controlViews: [UIView] = []

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

        backgroundImageView.frame = view.bounds
        blurView.frame = view.bounds
        mediaScrollView.frame = view.bounds
        layoutMediaPages()

        topShade.frame = CGRect(x: 0, y: 0, width: w, height: safeTop + 88)
        backButton.frame = CGRect(x: 12, y: safeTop + 8, width: 36, height: 36)
        searchButton.frame = CGRect(x: 56, y: safeTop + 8, width: max(0, w - 110), height: 36)

        // 底部 TabBar 固定 49pt + 安全区，信息区锚点改为 TabBar 顶部
        let tabH: CGFloat = 49
        let tabTop = h - safeBottom - tabH
        bottomTabBar.frame = CGRect(x: 0, y: tabTop, width: w, height: tabH + safeBottom)
        let slotW = w / 5
        for (i, btn) in tabButtons.enumerated() {
            btn.frame = CGRect(x: CGFloat(i) * slotW, y: 0, width: slotW, height: tabH)
        }
        plusButton.frame = CGRect(x: w / 2 - 22, y: 8, width: 44, height: 32)

        let infoH: CGFloat = 190
        let infoTop = tabTop - infoH
        bottomShade.frame = CGRect(x: 0, y: infoTop, width: w, height: infoH)
        bottomShade.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.forEach {
            $0.frame = bottomShade.bounds
        }

        let railX = w - 56
        let railTop = max(safeTop + 90, min(h * 0.34, infoTop - 300))
        railAvatar.frame = CGRect(x: railX, y: railTop, width: 44, height: 44)
        railAvatar.layer.cornerRadius = 22
        followBadge.frame = CGRect(x: railX + 32, y: railTop + 32, width: 18, height: 18)
        followBadge.layer.cornerRadius = 9

        let step: CGFloat = 58
        let first = railTop + 58
        likeIcon.frame = CGRect(x: railX + 9, y: first, width: 26, height: 26)
        likeCount.frame = CGRect(x: railX - 6, y: first + 27, width: 56, height: 16)
        commentIcon.frame = CGRect(x: railX + 9, y: first + step, width: 26, height: 26)
        commentCount.frame = CGRect(x: railX - 6, y: first + step + 27, width: 56, height: 16)
        favoriteIcon.frame = CGRect(x: railX + 9, y: first + step * 2, width: 26, height: 26)
        favoriteCount.frame = CGRect(x: railX - 6, y: first + step * 2 + 27, width: 56, height: 16)
        shareIcon.frame = CGRect(x: railX + 9, y: first + step * 3, width: 26, height: 26)
        shareCount.frame = CGRect(x: railX - 6, y: first + step * 3 + 27, width: 56, height: 16)

        let discSize: CGFloat = 42
        let discY = max(infoTop - discSize - 18, first + step * 4 + 6)
        discView.frame = CGRect(x: railX + 2, y: discY, width: discSize, height: discSize)
        discView.layer.cornerRadius = discSize / 2
        discHole.frame = CGRect(x: discView.frame.midX - 5, y: discView.frame.midY - 5, width: 10, height: 10)
        discHole.layer.cornerRadius = 5

        let left: CGFloat = 16
        let rightW: CGFloat = w - 84 - left
        // 音乐行贴底，但和 TabBar 顶边的进度条留出 6pt 呼吸空间
        let musicY = tabTop - 34
        musicLabel.frame = CGRect(x: left, y: musicY, width: rightW, height: 18)

        pageBars.frame = CGRect(x: left, y: musicY - 20, width: min(rightW, 140), height: 6)
        textLabel.preferredMaxLayoutWidth = rightW
        let textH = min(68, textLabel.sizeThatFits(CGSize(width: rightW, height: .greatestFiniteMagnitude)).height)
        let textY = musicY - 30 - textH
        textLabel.frame = CGRect(x: left, y: textY, width: rightW, height: textH)
        nameLabel.frame = CGRect(x: left, y: textY - 28, width: rightW, height: 22)

        // 进度条贴 TabBar 顶边（真实抖音：TabBar 上方一条细线）
        progressTrack.frame = CGRect(x: 0, y: tabTop - 1.5, width: w, height: 1.5)
        updateProgress()
    }

    private func buildUI() {
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        view.addSubview(backgroundImageView)
        blurView.alpha = 0.72
        blurView.isUserInteractionEnabled = false
        view.addSubview(blurView)

        mediaScrollView.isPagingEnabled = true
        mediaScrollView.showsHorizontalScrollIndicator = false
        mediaScrollView.showsVerticalScrollIndicator = false
        mediaScrollView.bounces = false
        mediaScrollView.delegate = self
        view.addSubview(mediaScrollView)

        topShade.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        topShade.isUserInteractionEnabled = false
        view.addSubview(topShade)
        bottomShade.backgroundColor = UIColor.clear
        bottomShade.isUserInteractionEnabled = false
        view.addSubview(bottomShade)
        applyBottomGradient()

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
        searchButton.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        searchButton.layer.cornerRadius = 18
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        view.addSubview(searchButton)

        railAvatar.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        railAvatar.contentMode = .scaleAspectFill
        railAvatar.clipsToBounds = true
        railAvatar.layer.borderWidth = 1.5
        railAvatar.layer.borderColor = UIColor.white.cgColor
        railAvatar.isUserInteractionEnabled = true
        railAvatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(followTapped)))
        view.addSubview(railAvatar)

        followBadge.text = "+"
        followBadge.textAlignment = .center
        followBadge.font = .systemFont(ofSize: 16, weight: .semibold)
        followBadge.textColor = .white
        followBadge.backgroundColor = UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1)
        view.addSubview(followBadge)

        likeIcon.image = UIImage(systemName: "heart.fill")
        likeIcon.tintColor = .white
        likeIcon.contentMode = .scaleAspectFit
        likeIcon.isUserInteractionEnabled = true
        likeIcon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(likeTapped)))
        view.addSubview(likeIcon)

        commentIcon.image = UIImage(systemName: "bubble.right.fill")
        commentIcon.tintColor = .white
        commentIcon.contentMode = .scaleAspectFit
        commentIcon.isUserInteractionEnabled = true
        commentIcon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(commentTapped)))
        view.addSubview(commentIcon)

        favoriteIcon.image = UIImage(systemName: "star.fill")
        favoriteIcon.tintColor = .white
        favoriteIcon.contentMode = .scaleAspectFit
        favoriteIcon.isUserInteractionEnabled = true
        favoriteIcon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(favoriteTapped)))
        view.addSubview(favoriteIcon)

        shareIcon.image = UIImage(systemName: "arrowshape.turn.up.right.fill")
        shareIcon.tintColor = .white
        shareIcon.contentMode = .scaleAspectFit
        shareIcon.isUserInteractionEnabled = true
        shareIcon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shareTapped)))
        view.addSubview(shareIcon)

        for label in [likeCount, commentCount, favoriteCount, shareCount] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.textAlignment = .center
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.7
            label.layer.shadowRadius = 2
            view.addSubview(label)
        }
        likeCount.text = "—"
        commentCount.text = "—"
        favoriteCount.text = "收藏"
        shareCount.text = "分享"

        discView.contentMode = .scaleAspectFill
        discView.clipsToBounds = true
        discView.backgroundColor = UIColor(white: 0.14, alpha: 1)
        discView.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        discView.layer.borderWidth = 2
        discView.isUserInteractionEnabled = true
        discView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(musicTapped)))
        view.addSubview(discView)

        discHole.backgroundColor = .black
        discHole.layer.borderColor = UIColor.white.cgColor
        discHole.layer.borderWidth = 1
        discHole.isUserInteractionEnabled = false
        view.addSubview(discHole)

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        swShadow(nameLabel)
        view.addSubview(nameLabel)

        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = .white
        textLabel.numberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        swShadow(textLabel)
        view.addSubview(textLabel)

        musicLabel.font = .systemFont(ofSize: 12)
        musicLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        musicLabel.numberOfLines = 1
        musicLabel.lineBreakMode = .byTruncatingTail
        swShadow(musicLabel)
        musicLabel.isUserInteractionEnabled = true
        musicLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(musicTapped)))
        view.addSubview(musicLabel)

        pageBars.axis = .horizontal
        pageBars.alignment = .center
        pageBars.distribution = .fillEqually
        pageBars.spacing = 3
        view.addSubview(pageBars)

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        view.addSubview(progressTrack)
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)

        likeBurst.image = UIImage(systemName: "heart.fill")
        likeBurst.tintColor = UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1)
        likeBurst.contentMode = .scaleAspectFit
        likeBurst.alpha = 0
        view.addSubview(likeBurst)

        buildBottomTabBar()

        controlViews = [topShade, bottomShade, backButton, searchButton, railAvatar, followBadge,
                        likeIcon, likeCount, commentIcon, commentCount, favoriteIcon, favoriteCount,
                        shareIcon, shareCount, discView, discHole, musicLabel, progressTrack,
                        bottomTabBar]

        singleTap.addTarget(self, action: #selector(singleTapped))
        singleTap.delegate = self
        singleTap.requiresExclusiveTouchType = false
        singleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(singleTap)

        doubleTap.addTarget(self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
    }

    private func buildBottomTabBar() {
        bottomTabBar.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.96)
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        bottomTabBar.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: bottomTabBar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bottomTabBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bottomTabBar.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        view.addSubview(bottomTabBar)

        let specs: [(String, String)] = [
            ("house.fill", "首页"),
            ("person.2.fill", "朋友"),
            ("", ""),
            ("bubble.right.fill", "消息"),
            ("person.fill", "我")
        ]
        for (i, spec) in specs.enumerated() {
            let btn = UIButton(type: .system)
            if i == 2 {
                btn.isUserInteractionEnabled = false
            } else {
                var cfg = UIButton.Configuration.plain()
                cfg.image = UIImage(systemName: spec.0)
                cfg.title = spec.1
                cfg.imagePlacement = .top
                cfg.imagePadding = 3
                cfg.baseForegroundColor = UIColor.white.withAlphaComponent(0.62)
                cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var out = incoming
                    out.font = UIFont.systemFont(ofSize: 10)
                    return out
                }
                btn.configuration = cfg
                btn.tag = i
                btn.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            }
            tabButtons.append(btn)
            bottomTabBar.addSubview(btn)
        }

        plusButton.backgroundColor = .white
        plusButton.tintColor = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        plusButton.setImage(UIImage(systemName: "plus"), for: .normal)
        plusButton.layer.cornerRadius = 8
        plusButton.isUserInteractionEnabled = false
        bottomTabBar.addSubview(plusButton)
    }

    @objc private func tabTapped(_ sender: UIButton) {
        // 首页 / 我 回到个人页；朋友 / 消息暂无数据，保持当前页
        if sender.tag == 0 || sender.tag == 4 { onDismiss?() }
    }

    private func applyBottomGradient() {
        bottomShade.layer.sublayers?.removeAll(where: { $0 is CAGradientLayer })
        let g = CAGradientLayer()
        g.frame = bottomShade.bounds
        g.colors = [UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.35).cgColor,
                    UIColor.black.withAlphaComponent(0.86).cgColor]
        g.locations = [0, 0.42, 1]
        bottomShade.layer.insertSublayer(g, at: 0)
    }

    // MARK: 数据

    private func loadDetail() {
        let id = item.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let d = try? await APIClient.shared.archiveItem(id: id) else {
                self.nameLabel.text = "@\(self.item.authorName ?? "抖音用户")"
                self.textLabel.text = self.item.cleanText
                return
            }
            guard self.view.window != nil else { return }
            self.detail = d
            self.apply(detail: d)
            self.buildMediaPages()
            self.playMusicIfNeeded()
            self.startProgressTimer()
            if let url = d.authorAvatar, !url.isEmpty {
                self.avatarLoader.onImage = { [weak self] image in self?.railAvatar.image = image }
                self.avatarLoader.load(remoteURL: url)
            }
            if let cover = d.music?.coverURL, !cover.isEmpty {
                self.discCoverLoader.onImage = { [weak self] image in self?.discView.image = image }
                self.discCoverLoader.load(remoteURL: cover)
            }
        }
    }

    private func apply(detail d: ArchiveDetail) {
        nameLabel.text = "@\(d.authorName ?? item.authorName ?? "抖音用户")"
        textLabel.text = d.cleanText.isEmpty ? "（无正文）" : d.cleanText
        likeCount.text = swNumber(d.likes ?? 0)
        commentCount.text = swNumber(d.commentsCount ?? 0)
        if let collect = d.collectCount { favoriteCount.text = swNumber(collect) }
        if let share = d.shareCount { shareCount.text = swNumber(share) }
        if railAvatar.image == nil {
            railAvatar.image = Self.placeholder(letter: d.authorName ?? "抖")
        }
        let title = d.music?.title ?? "原声"
        let author = d.music?.author ?? d.authorName ?? "抖音用户"
        musicLabel.text = "♫ \(title) - \(author)"
        discView.image = Self.placeholder(letter: title)
    }

    private func buildMediaPages() {
        guard let d = detail, !d.media.isEmpty else { return }
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }

        mediaScrollView.subviews.forEach { $0.removeFromSuperview() }
        mediaViews.removeAll()
        mediaLoaders.removeAll()
        pageBars.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (i, media) in d.media.enumerated() {
            let imageView = UIImageView(frame: CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h))
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.backgroundColor = .black
            mediaScrollView.addSubview(imageView)
            mediaViews.append(imageView)

            let loader = ImageLoader()
            loader.onImage = { [weak self, weak imageView] image in
                guard let imageView, let self else { return }
                imageView.image = image
                if i == 0 { self.backgroundImageView.image = image }
            }
            loader.load(itemID: d.id, seq: media.seq, tier: .detail)
            mediaLoaders.append(loader)

            let bar = UIView()
            bar.backgroundColor = UIColor.white.withAlphaComponent(i == 0 ? 0.95 : 0.35)
            bar.layer.cornerRadius = 1.5
            pageBars.addArrangedSubview(bar)
        }
        mediaScrollView.contentSize = CGSize(width: w * CGFloat(d.media.count), height: h)
        currentMediaIndex = 0
    }

    private func layoutMediaPages() {
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return }
        for (i, imageView) in mediaViews.enumerated() {
            imageView.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
        mediaScrollView.contentSize = CGSize(width: w * CGFloat(max(1, mediaViews.count)), height: h)
    }

    // MARK: 手势

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === singleTap || gesture === doubleTap else { return true }
        let p = gesture.location(in: view)
        guard let hit = view.hitTest(p, with: nil) else { return true }
        for control in controlViews where hit === control || hit.isDescendant(of: control) {
            return false
        }
        return true
    }

    @objc private func singleTapped() {
        guard let d = detail else { return }
        let player = FeedMusicPlayer.shared
        if player.isPlaying(itemID: d.id) {
            player.pause()
            stopDiscAnimation()
        } else {
            player.playIfNeeded(itemID: d.id)
            startDiscAnimation()
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        liked = true
        likeIcon.tintColor = UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1)
        if let likes = detail?.likes { likeCount.text = swNumber(likes + 1) }
        likeBurst.frame = CGRect(x: view.bounds.midX - 45, y: view.bounds.midY - 45, width: 90, height: 90)
        likeBurst.alpha = 1
        likeBurst.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.5,
                       animations: { self.likeBurst.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) },
                       completion: { _ in
            UIView.animate(withDuration: 0.35) { self.likeBurst.alpha = 0 }
        })
    }

    @objc private func backTapped() { onDismiss?() }
    @objc private func searchTapped() { onSearch?() }

    @objc private func likeTapped() {
        guard let d = detail else { return }
        liked.toggle()
        likeIcon.tintColor = liked ? UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1) : .white
        likeCount.text = swNumber(max(0, d.likes ?? 0) + (liked ? 1 : 0))
    }

    @objc private func favoriteTapped() {
        favorited.toggle()
        favoriteIcon.tintColor = favorited ? UIColor(red: 1, green: 0.78, blue: 0.12, alpha: 1) : .white
    }

    @objc private func followTapped() {
        followed.toggle()
        followBadge.isHidden = followed
    }

    @objc private func commentTapped() {
        guard let d = detail else { return }
        let vc = DouyinCommentsVC(detail: d)
        present(vc, animated: true)
    }

    @objc private func shareTapped() {
        guard let d = detail else { return }
        var items: [Any] = [d.cleanText]
        if let url = d.url, !url.isEmpty { items.append(url) }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(vc, animated: true)
    }

    @objc private func musicTapped() {
        guard let d = detail else { return }
        let player = FeedMusicPlayer.shared
        if player.isPlaying(itemID: d.id) {
            player.pause()
            stopDiscAnimation()
        } else {
            player.playIfNeeded(itemID: d.id)
            startDiscAnimation()
        }
    }

    // MARK: 分页 / 进度

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === mediaScrollView, view.bounds.width > 0 else { return }
        let idx = Int(round(scrollView.contentOffset.x / view.bounds.width))
        guard idx != currentMediaIndex else { return }
        currentMediaIndex = idx
        for (i, bar) in pageBars.arrangedSubviews.enumerated() {
            bar.backgroundColor = UIColor.white.withAlphaComponent(i == idx ? 0.95 : 0.35)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateProgress() }
        }
    }

    private func updateProgress() {
        let p = CGFloat(FeedMusicPlayer.shared.progress)
        progressFill.frame = CGRect(x: 0, y: 0, width: progressTrack.bounds.width * p, height: 2)
    }

    private func playMusicIfNeeded() {
        guard let d = detail, d.music != nil else { return }
        FeedMusicPlayer.shared.play(itemID: d.id)
        startDiscAnimation()
    }

    private func startDiscAnimation() {
        discView.layer.removeAnimation(forKey: "cloneDisc")
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.toValue = NSNumber(value: Double.pi * 2)
        a.duration = 4
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        discView.layer.add(a, forKey: "cloneDisc")
        discAnimation = a
    }

    private func stopDiscAnimation() {
        discView.layer.removeAnimation(forKey: "cloneDisc")
        discAnimation = nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        playMusicIfNeeded()
        startProgressTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        progressTimer?.invalidate()
        progressTimer = nil
        stopDiscAnimation()
    }

    private static func placeholder(letter: String) -> UIImage {
        let size = CGSize(width: 72, height: 72)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = String(letter.prefix(1)) as NSString
            let font = UIFont.systemFont(ofSize: 28, weight: .semibold)
            let rect = text.boundingRect(with: size,
                                         options: .usesLineFragmentOrigin,
                                         attributes: [.font: font],
                                         context: nil)
            text.draw(in: CGRect(x: (size.width - rect.width) / 2,
                                 y: (size.height - rect.height) / 2,
                                 width: rect.width,
                                 height: rect.height),
                      withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }
}

// MARK: - 评论抽屉

private final class DouyinCommentsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let detail: ArchiveDetail
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let grip = UIView()

    init(detail: ArchiveDetail) {
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        grip.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        grip.layer.cornerRadius = 2
        view.addSubview(grip)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.08)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "comment")
        view.addSubview(tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grip.frame = CGRect(x: view.bounds.midX - 18, y: 8, width: 36, height: 4)
        tableView.frame = CGRect(x: 0, y: 20, width: view.bounds.width, height: view.bounds.height - 20)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if #available(iOS 15.0, *) {
            sheetPresentationController?.detents = [.medium(), .large()]
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, detail.comments.count)
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "comment", for: indexPath)
        cell.backgroundColor = .clear
        cell.textLabel?.textColor = .white
        cell.textLabel?.numberOfLines = 3
        cell.textLabel?.font = .systemFont(ofSize: 14)
        if detail.comments.isEmpty {
            cell.textLabel?.text = "暂无已归档评论"
            cell.textLabel?.textColor = UIColor.white.withAlphaComponent(0.5)
        } else {
            let c = detail.comments[indexPath.row]
            cell.textLabel?.text = "\(c.authorName ?? "用户")：\(c.text ?? "")"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "评论 \(detail.commentsCount ?? detail.comments.count)"
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        view.tintColor = UIColor.clear
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = UIColor.white.withAlphaComponent(0.6)
        }
    }
}

// MARK: - 小工具

private func swNumber(_ n: Int) -> String {
    if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
}

private func swShadow(_ label: UILabel) {
    label.layer.shadowColor = UIColor.black.cgColor
    label.layer.shadowOpacity = 0.75
    label.layer.shadowRadius = 3
    label.layer.shadowOffset = CGSize(width: 0, height: 1)
}
