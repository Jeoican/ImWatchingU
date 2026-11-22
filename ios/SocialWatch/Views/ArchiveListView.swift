import SwiftUI

/// 内容库。
///
/// 左右滑动切换来源库
/// ------------------
/// 顶部标签栏是「指示器 + 快捷入口」，真正的切换靠 TabView 的 page 样式：
/// 手指在列表上左右划，会像翻页一样滑到相邻的库（全部 / 小红书 / 微博 /
/// 抖音 / 网易云），而不是让标签栏自己横向滚动。
/// 每个库是一页独立视图，各自持有自己的分页游标与缓存，互不干扰。
///
/// 分页必须用游标而不是 offset
/// ---------------------------
/// 后端 `next_cursor` 是 `posted_at:id` 复合键。用 offset 分页时，
/// 若期间有新内容入库，第二页会重复或漏条。游标不存在这个问题。
/// 所以这里只存「当前游标」和「是否还有更多」，不做页码。
struct ArchiveListView: View {
    @State private var filter: StateFilter = .all

    #if DEBUG
    /// 自动化验证：SW_SOURCE=weibo|xiaohongshu|douyin|netease 预设来源
    @State private var sourceFilter: SourceFilter = {
        switch ProcessInfo.processInfo.environment["SW_SOURCE"] {
        case "weibo":       return .weibo
        case "xiaohongshu": return .xiaohongshu
        case "douyin":      return .douyin
        case "netease":     return .netease
        default:            return .all
        }
    }()
    #else
    @State private var sourceFilter: SourceFilter = .all
    #endif

    /// TabView 的选中绑定：点击标签和左右滑页都走这里，两者天然同步。
    /// 注意不要在这里加「值相同就 return」的短路——TabView 翻页时会连续回写，
    /// 短路会让系统与视图状态短暂不一致，表现为滑到某页后又弹回。
    private var tabSelection: Binding<SourceFilter> {
        Binding(
            get: { sourceFilter },
            set: { sourceFilter = $0 }
        )
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 标签栏固定在外层，不参与任何滚动，永远不会被列表内容挤变形。
                sourceTabBar

                TabView(selection: tabSelection) {
                    ForEach(SourceFilter.allCases) { f in
                        // 标签栏按顺序排列，页面也按顺序排列，滑动方向与标签一致。
                        ArchiveSourcePage(source: f, filter: filter)
                            .tag(f)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("内容库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(StateFilter.allCases) { f in
                            Button {
                                filter = f
                            } label: {
                                Label(f.label, systemImage: filter == f ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    /// 顶部来源标签栏：点击跳页，不靠自身滚动。
    /// 标签等分屏宽，五个选项一屏放得下，也就没有"栏滑走看不见"的问题。
    private var sourceTabBar: some View {
        HStack(spacing: 0) {
            ForEach(SourceFilter.allCases) { f in
                Button {
                    // 点击标签即切换 TabView 选中页，滑页动画由 TabView 自己负责，
                    // 这里不要再套 withAnimation，否则会和系统翻页动画叠加成抖动。
                    sourceFilter = f
                } label: {
                    VStack(spacing: 6) {
                        Text(f.label)
                            .font(.system(size: 14, weight: sourceFilter == f ? .semibold : .regular))
                            .foregroundColor(sourceFilter == f
                                             ? Color(red: 0.82, green: 0.28, blue: 0.22)
                                             : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Rectangle()
                            .fill(sourceFilter == f
                                  ? Color(red: 0.82, green: 0.28, blue: 0.22)
                                  : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(f.label)
                .accessibilityAddTraits(sourceFilter == f ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 4)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - 单个来源库的一页

/// 一个来源库的独立列表页。每页自己管数据，互不影响——
/// 滑到哪页就加载哪页，已加载过的保留，来回滑不会重复请求。
private struct ArchiveSourcePage: View {
    let source: SourceFilter
    let filter: StateFilter

    @State private var items: [ArchiveItem] = []
    @State private var stats: [String: TargetStats] = [:]
    @State private var nextCursor: String?
    @State private var hasMore: Bool = false
    @State private var isLoading = false
    @State private var errorText: String?

    @State private var playlists: [MusicPlaylist] = []
    @State private var isLoadingPlaylists = false
    @State private var playlistError: String?

    private var cacheKey: String {
        "archive:list:\(source.rawValue):\(filter.rawValue)"
    }

    var body: some View {
        Group {
            if source == .douyin {
                // 抖音走沉浸式全屏 feed：上下滑切换作品，点开看全部图。
                // 数据加载/分页/筛选仍复用本页下面那套，只是换了呈现方式。
                if let errorText {
                    VStack(spacing: 14) {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重试") { reload() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                } else {
                    DouyinFeedView(items: items, hasMore: hasMore) {
                        load(page: false)
                    }
                }
            } else if source == .netease {
                List { neteaseSections }
                    .listStyle(.plain)
                    .refreshable { reload(keepCurrent: true) }
            } else {
                List { archiveSections }
                    .listStyle(.plain)
                    .refreshable { reload(keepCurrent: true) }
            }
        }
        // task(id:) 在首次出现、以及切换状态筛选时都会触发
        .task(id: filter) { loadInitial() }
    }

    // MARK: 网易云页

    @ViewBuilder
    private var neteaseSections: some View {
        if let playlistError {
            Section {
                Label(playlistError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14)).foregroundColor(.red)
            }
        }
        Section {
            if isLoadingPlaylists && playlists.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if playlists.isEmpty && playlistError == nil {
                Text("还没有采集到歌单，先跑一次巡检吧")
                    .font(.system(size: 14)).foregroundColor(.secondary)
            }
            ForEach(playlists) { pl in
                NavigationLink(destination: SongListView(playlist: pl)) {
                    MusicPlaylistRow(playlist: pl)
                }
            }
        } header: {
            Text("我的歌单 · \(playlists.count)")
        }
    }

    // MARK: 归档页

    @ViewBuilder
    private var archiveSections: some View {
        if let errorText {
            Section {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
        }

        Section {
            ForEach(items) { item in
                NavigationLink(destination: ArchiveDetailView(itemID: item.id)) {
                    ArchiveRow(item: item)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
        } header: {
            headerRow
        }

        if hasMore {
            Section {
                loadMoreButton
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("共 \(totalCount) 条")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            if !stats.isEmpty {
                Text(mediaSizeText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 统计必须按当前页的来源过滤：
    /// 后端 stats 返回的是全部平台的合计，若不过滤，微博页也会显示"共 53 条"（全部的量），
    /// 而实际只列出微博的条目，数量对不上。
    private var visibleStats: [TargetStats] {
        guard let p = source.platform else { return Array(stats.values) }
        return stats.values.filter { $0.platform == p }
    }

    private var totalCount: Int {
        visibleStats.reduce(0) { $0 + $1.total }
    }

    private var mediaSizeText: String {
        let bytes = visibleStats.reduce(0) { $0 + $1.mediaBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var loadMoreButton: some View {
        Button {
            load(page: false)
        } label: {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("加载更多").font(.system(size: 15))
                }
                Spacer()
            }
            .frame(height: 44)
        }
        .disabled(isLoading)
    }

    // MARK: 加载

    private func loadInitial() {
        if source == .netease {
            guard playlists.isEmpty, !isLoadingPlaylists else { return }
            loadPlaylists()
        } else {
            // 先灌缓存（秒开），再后台刷新覆盖
            if let cached = DataCache.load(cacheKey, as: ArchiveListSnapshot.self,
                                           maxAge: 30 * 24 * 3600) {
                items = cached.items
                nextCursor = cached.nextCursor
                hasMore = cached.hasMore
                stats = cached.stats
            }
            reload(keepCurrent: true)
        }
    }

    private func loadPlaylists() {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        playlistError = nil
        Task {
            do {
                let list = try await APIClient.shared.musicPlaylists()
                await MainActor.run { playlists = list; isLoadingPlaylists = false }
            } catch let e as APIError {
                await MainActor.run {
                    let host = CredentialStore.shared.load()?.normalizedBaseURL?.absoluteString ?? "未配置"
                    playlistError = "\(e.errorDescription ?? "加载失败")\n服务器：\(host)"
                    isLoadingPlaylists = false
                }
            } catch {
                await MainActor.run {
                    playlistError = error.localizedDescription
                    isLoadingPlaylists = false
                }
            }
        }
    }

    private func reload(keepCurrent: Bool = false) {
        guard !isLoading else { return }
        if !keepCurrent {
            items = []
            nextCursor = nil
            hasMore = false
        }
        load(page: true)
    }

    private func load(page: Bool) {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        let cursor = page ? nil : nextCursor
        let state: ContentState? = filter == .all ? nil : filter.state
        let platform: String? = source == .all ? nil : source.platform

        #if DEBUG
        NSLog("[ArchivePage] load start source=%@ platform=%@ cursor=%@",
              source.rawValue, platform ?? "nil", cursor ?? "nil")
        #endif

        Task {
            do {
                let res = try await APIClient.shared.archiveList(platform: platform,
                                                                 state: state,
                                                                 cursor: cursor,
                                                                 limit: 30)
                #if DEBUG
                NSLog("[ArchivePage] load ok source=%@ items=%d", source.rawValue, res.items.count)
                #endif
                await MainActor.run {
                    if page {
                        items = res.items
                    } else {
                        let existing = Set(items.map(\.id))
                        items.append(contentsOf: res.items.filter { !existing.contains($0.id) })
                    }
                    nextCursor = res.nextCursor
                    hasMore = res.hasMore
                    stats = res.stats
                    isLoading = false
                    if page {
                        let snap = ArchiveListSnapshot(items: res.items,
                                                       nextCursor: res.nextCursor,
                                                       hasMore: res.hasMore,
                                                       stats: res.stats)
                        DataCache.save(self.cacheKey, value: snap)
                    }
                }
            } catch let e as APIError {
                #if DEBUG
                NSLog("[ArchivePage] APIError source=%@ desc=%@", source.rawValue, e.errorDescription ?? "nil")
                #endif
                await MainActor.run {
                    // 有缓存时不弹错误条遮住列表（旧数据照常可看）
                    if items.isEmpty {
                        let host = CredentialStore.shared.load()?.normalizedBaseURL?.absoluteString ?? "未配置"
                        errorText = "\(e.errorDescription ?? "加载失败")\n服务器：\(host)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    if items.isEmpty { errorText = error.localizedDescription }
                    isLoading = false
                }
            }
        }
    }
}

/// 内容库列表的缓存快照：一次筛选组合下的第一页 + 分页游标 + 统计。
struct ArchiveListSnapshot: Codable, Sendable {
    let items: [ArchiveItem]
    let nextCursor: String?
    let hasMore: Bool
    let stats: [String: TargetStats]
}

// MARK: - 筛选

/// 来源筛选。值直接对应后端 `platform` 参数（Platform.rawValue）。
/// 只列出真实存在的四个平台，不含 unknown——后端没有 unknown 这个值，
/// 选它等于查不到任何东西，没有意义。
enum SourceFilter: String, CaseIterable, Identifiable {
    case all, xiaohongshu, weibo, douyin, netease
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:         return "全部"
        case .weibo:       return Platform.weibo.label
        case .xiaohongshu: return Platform.xiaohongshu.label
        case .douyin:      return Platform.douyin.label
        case .netease:     return Platform.netease.label
        }
    }

    var platform: String? { self == .all ? nil : rawValue }
}

enum StateFilter: String, CaseIterable, Identifiable {
    case all, alive, deleted, hidden
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "全部"
        case .alive:   return "在线"
        case .deleted: return "已删除"
        case .hidden:  return "超出窗口"
        }
    }

    var state: ContentState? {
        switch self {
        case .all: return nil
        default: return ContentState(rawValue: rawValue)
        }
    }
}

// MARK: - 行

struct ArchiveRow: View {
    let item: ArchiveItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.cleanText.isEmpty ? "（无正文）" : item.cleanText)
                    .font(.system(size: 15))
                    .lineLimit(3)
                    .foregroundColor(item.state == .deleted ? .secondary : .primary)

                HStack(spacing: 8) {
                    Text(dateText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if item.state != .alive {
                        Text(item.state.label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateBadgeBG)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    if let likes = item.likes, likes > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "heart")
                            Text("\(likes)")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }

                    // 评论数恒显示（哪怕 0）：后端当前评论数为 0 是普遍情况，
                    // 若按 >0 隐藏，用户根本看不到这一项，等于没做。
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.right")
                        Text("\(item.commentsCount ?? 0)")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                // 元信息行整体禁止压缩：加了评论数后四项并排，默认会被挤到换行
                // （日期断成两行、数字竖排）。让它保持固有宽度，由缩略图区让位。
                // 注意：fixedSize 只能加在整行，加在单个 Label 上会把数字文本挤没。
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)

            // 缩略图条：最多显示 3 张，用 thumb=2（200px / 8KB）。
            // 用 900px 会让一次列表 30 条×3 张变成 9.4MB，不可接受。
            if item.hasMedia {
                HStack(spacing: 4) {
                    ForEach(0..<min(3, max(1, item.mediaTotal)), id: \.self) { i in
                        RemoteImage(itemID: item.id, seq: i + 1, tier: .list, aspectRatio: 1.0)
                            .frame(width: 52, height: 52)
                    }
                    if item.mediaTotal > 3 {
                        Text("+\(item.mediaTotal - 3)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: item.postedDate)
    }

    private var stateBadgeBG: Color {
        switch item.state {
        case .deleted: return Color(red: 0.94, green: 0.97, blue: 0.95)
        case .hidden:  return Color(red: 0.96, green: 0.96, blue: 0.95)
        default:       return Color.clear
        }
    }
}
