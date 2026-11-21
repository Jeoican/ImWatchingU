import SwiftUI

/// 内容库列表。
///
/// 分页必须用游标而不是 offset
/// ---------------------------
/// 后端 `next_cursor` 是 `posted_at:id` 复合键。用 offset 分页时，
/// 若期间有新内容入库，第二页会重复或漏条。游标不存在这个问题。
/// 所以这里只存「当前游标」和「是否还有更多」，不做页码。
struct ArchiveListView: View {
    @State private var items: [ArchiveItem] = []
    @State private var stats: [String: TargetStats] = [:]
    @State private var nextCursor: String?
    @State private var hasMore: Bool = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var filter: StateFilter = .all
    /// 网易云标签下直接展示的歌单
    @State private var playlists: [MusicPlaylist] = []
    @State private var isLoadingPlaylists = false
    @State private var playlistError: String?
    #if DEBUG
    /// 自动化验证：SW_SOURCE=weibo|xiaohongshu|douyin|netease 预设来源筛选
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

    var body: some View {
        NavigationView {
            // 标签栏放在 List 之外的 VStack 里，而不是 safeAreaInset。
            // 原因：plain List 的 Section header 吸顶 + safeAreaInset 的固定视图
            // 在 iOS 16 上滚动时会互相挤压，出现标签栏抖动/被盖住的显示异常。
            // 用 VStack 把它彻底移出滚动坐标系，标签栏就永久固定在顶部。
            VStack(spacing: 0) {
                sourceTabBar
                List {
                if sourceFilter == .netease {
                    // 网易云：直接列出歌单，点进去是歌曲列表并可播放
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
                } else {
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
                }
                .listStyle(.plain)
            }
            .navigationTitle("内容库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(StateFilter.allCases) { f in
                            Button {
                                if filter != f { filter = f; reload() }
                            } label: {
                                Label(f.label, systemImage: filter == f ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable { loadForCurrentTab() }
            .task { loadForCurrentTab() }
        }
    }

    /// 当前筛选组合对应的缓存 key（来源 + 状态，分页游标不入 key）。
    private var listCacheKey: String {
        "archive:list:\(sourceFilter.rawValue):\(filter.rawValue)"
    }

    /// 按当前来源标签加载：网易云加载歌单，其余加载归档内容。
    private func loadForCurrentTab() {
        if sourceFilter == .netease {
            loadPlaylists()
        } else {
            // 先显示上次缓存（秒开），再后台刷新；没有缓存也要刷新
            if let cached = DataCache.load(listCacheKey, as: ArchiveListSnapshot.self,
                                           maxAge: 30 * 24 * 3600) {
                items = cached.items
                nextCursor = cached.nextCursor
                hasMore = cached.hasMore
                stats = cached.stats
            }
            reload(keepCurrent: true)
        }
    }

    /// 顶部来源标签栏。横向可滚动：标签多/屏窄时能左右翻，选中的自动回到视野中央。
    /// 只放平台文字，不显示来源徽章——徽章留给列表条目，标签本身要克制。
    private var sourceTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(SourceFilter.allCases) { f in
                        Button {
                            if sourceFilter != f {
                                sourceFilter = f
                                loadForCurrentTab()
                                withAnimation { proxy.scrollTo(f.id, anchor: .center) }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Text(f.label)
                                    .font(.system(size: 14, weight: sourceFilter == f ? .semibold : .regular))
                                    .foregroundColor(sourceFilter == f ? Color(red: 0.82, green: 0.28, blue: 0.22) : .secondary)
                                Rectangle()
                                    .fill(sourceFilter == f ? Color(red: 0.82, green: 0.28, blue: 0.22) : Color.clear)
                                    .frame(height: 2)
                            }
                            // 固定宽度而非 maxWidth:.infinity：这样内容宽度可被撑开，
                            // 横向 ScrollView 才有可滚动的空间，能左右翻。
                            .frame(width: 76)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(f.label)
                        .id(f.id)
                    }
                }
                .frame(height: 40)
            }
            .background(Color.white)
            .overlay(
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 0.5),
                alignment: .bottom
            )
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

    /// 统计跟随来源筛选：筛选微博时只算微博的量，避免"共 53 条"却只列出微博的困惑。
    private var visibleStats: [TargetStats] {
        guard let p = sourceFilter.platform else { return Array(stats.values) }
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
            loadMore()
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
            .frame(height: 44)          // 触控最小目标
        }
        .disabled(isLoading)
    }

    // MARK: 数据

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
                await MainActor.run { playlistError = error.localizedDescription; isLoadingPlaylists = false }
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

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        load(page: false)
    }

    private func load(page: Bool) {
        isLoading = true
        errorText = nil
        let cursor = page ? nil : nextCursor
        let state: ContentState? = filter == .all ? nil : filter.state
        let platform: String? = sourceFilter == .all ? nil : sourceFilter.platform

        Task {
            do {
                let res = try await APIClient.shared.archiveList(platform: platform, state: state, cursor: cursor, limit: 30)
                await MainActor.run {
                    if page {
                        items = res.items
                    } else {
                        // 去重：游标理论上不会重复，但网络重试时可能拿到同一批
                        let existing = Set(items.map(\.id))
                        items.append(contentsOf: res.items.filter { !existing.contains($0.id) })
                    }
                    nextCursor = res.nextCursor
                    hasMore = res.hasMore
                    stats = res.stats
                    isLoading = false
                    // 缓存当前筛选组合的第一页快照，供下次进入/断网时秒开
                    if page {
                        let snap = ArchiveListSnapshot(items: res.items,
                                                       nextCursor: res.nextCursor,
                                                       hasMore: res.hasMore,
                                                       stats: res.stats)
                        DataCache.save(self.listCacheKey, value: snap)
                    }
                }
            } catch let e as APIError {
                await MainActor.run {
                    // 带上服务器地址：真机上最常见的"打不开"是手机连不上内网 IP，
                    // 光说"网络错误"用户没法判断，把地址亮出来一眼就能看出配错没。
                    // 有缓存时不弹错误条遮住列表（旧数据照常可看）。
                    if items.isEmpty {
                        let host = CredentialStore.shared.load()?.normalizedBaseURL?.absoluteString ?? "未配置"
                        errorText = "\(e.errorDescription ?? "加载失败")\n服务器：\(host)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

/// 内容库列表的缓存快照：一次筛选组合下的第一页 + 分页游标 + 统计。
/// 分页后续页不缓存（避免多页累积写入复杂），下次进来先显示第一页缓存再自动刷新。
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
