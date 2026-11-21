import Foundation

// MARK: - 看板全量状态
//
// 对应 `GET /api/state`。后端由 report.collect_payload + webapp._build_state_uncached
// 聚合而成，字段多且杂。设计原则与 ArchiveModels 一致：
//   1. 能用可选/默认值兜底的就别让它解码失败 —— 后端加字段、某平台缺字段是常态；
//   2. 枚举用 unknown 降级，不直接 fail；
//   3. 只声明 App 真正会渲染的字段，其余一律忽略（Codable 默认忽略未知键）。

struct DashboardState: Codable, Sendable {
    let generatedAt: String?
    let serverTime: Int?
    let cards: [MonitorCard]
    let runs: [RunRecord]
    let targets: [MonitorTarget]
    let config: ServerConfig
    let login: LoginStatus
    let check: CheckStatus
    let archiveStats: [String: TargetStats]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case serverTime = "server_time"
        case cards, runs, targets, config, login, check
        case archiveStats = "archive_stats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        serverTime = try c.decodeIfPresent(Int.self, forKey: .serverTime)
        let decodedCards = try c.decodeIfPresent([MonitorCard].self, forKey: .cards) ?? []
        let decodedRuns = try c.decodeIfPresent([RunRecord].self, forKey: .runs) ?? []
        runs = decodedRuns
        targets = try c.decodeIfPresent([MonitorTarget].self, forKey: .targets) ?? []
        config = try c.decodeIfPresent(ServerConfig.self, forKey: .config) ?? ServerConfig()
        login = try c.decodeIfPresent(LoginStatus.self, forKey: .login) ?? LoginStatus()
        check = try c.decodeIfPresent(CheckStatus.self, forKey: .check) ?? CheckStatus()
        archiveStats = try c.decodeIfPresent([String: TargetStats].self, forKey: .archiveStats) ?? [:]

        // runs 按时间倒序（后端 ORDER BY ran_at DESC），每个 target 取第一条即最近一次。
        // 只认 status=ok 的巡检，失败的留给卡片自己显示"暂无成功记录"。
        var latestByTarget: [String: String] = [:]
        for run in decodedRuns where run.isOK {
            if let target = run.target, latestByTarget[target] == nil {
                latestByTarget[target] = run.time
            }
        }
        cards = decodedCards.map { card in
            var c = card
            c.lastRunTime = latestByTarget[card.key]
            return c
        }
    }
}

// MARK: - 监控卡片

/// `cards[]`。注意 `stats` 后端给的是三元组数组 `[标签, 数值, 样式]`，
/// 数值可能是 Int（新增歌曲 3）也可能是 String（粉丝净增 "+3"），
/// 所以必须用自定义解码而不是固定的元组类型。
struct MonitorCard: Codable, Identifiable, Sendable {
    let key: String
    let name: String
    /// 平台中文名（后端 PLAT_NAME 映射后）
    let platform: String
    let platformKey: String
    let avatar: String?
    let enabled: Bool
    let head: [String: Int]
    let stats: [StatTriple]
    let events: [ChangeEvent]
    let playlists: [PlaylistDetail]
    let recentPosts: [RecentPost]
    let archive: ArchiveSummary?
    /// 该目标最近一次巡检时间。后端 card 本身不带，由 DashboardState 解码后
    /// 从 runs[] 按 target_key 回填（见 DashboardState.init）。
    var lastRunTime: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name, platform, avatar, enabled, head, stats, events, playlists, archive
        case platformKey = "platform_key"
        case recentPosts = "recent_posts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        platformKey = try c.decodeIfPresent(String.self, forKey: .platformKey) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        head = try c.decodeIfPresent([String: Int].self, forKey: .head) ?? [:]
        stats = try c.decodeIfPresent([StatTriple].self, forKey: .stats) ?? []
        events = try c.decodeIfPresent([ChangeEvent].self, forKey: .events) ?? []
        playlists = try c.decodeIfPresent([PlaylistDetail].self, forKey: .playlists) ?? []
        recentPosts = try c.decodeIfPresent([RecentPost].self, forKey: .recentPosts) ?? []
        archive = try c.decodeIfPresent(ArchiveSummary.self, forKey: .archive)
        lastRunTime = nil
    }

    var platformEnum: Platform {
        Platform(rawValue: platformKey) ?? .unknown
    }

    /// 卡片头指标-stable 排序（字典无序，UI 需要确定顺序）
    var sortedHead: [(key: String, value: Int)] {
        let order = ["歌单", "歌曲", "粉丝", "关注", "微博", "作品", "笔记"]
        return head.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? Int.max
            let ib = order.firstIndex(of: b.key) ?? Int.max
            return ia == ib ? a.key < b.key : ia < ib
        }
    }
}

/// `[标签, 数值, 样式]` 三元组。数值是宽松类型，统一转成字符串显示。
struct StatTriple: Codable, Sendable {
    let label: String
    let valueText: String
    let style: String

    init(label: String, valueText: String, style: String) {
        self.label = label
        self.valueText = valueText
        self.style = style
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        label = (try? container.decode(String.self)) ?? ""
        // 数值可能是 number 也可能是 string，两种都试
        let text: String
        if let n = try? container.decode(Int.self) {
            text = String(n)
        } else if let s = try? container.decode(String.self) {
            text = s
        } else {
            text = ""
        }
        valueText = text
        style = (try? container.decode(String.self)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(label)
        try container.encode(valueText)
        try container.encode(style)
    }

    var isAdd: Bool { style == "add" }
}

// MARK: - 变更事件

struct ChangeEvent: Codable, Identifiable, Sendable {
    let id: Int
    let targetKey: String
    let platform: String
    let scope: String?
    let scopeName: String?
    let eventType: String
    let itemType: String?
    let itemId: String?
    let itemName: String?
    let itemExtra: EventExtra
    let delta: Int?
    let detectedAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case targetKey = "target_key"
        case platform, scope
        case scopeName = "scope_name"
        case eventType = "event_type"
        case itemType = "item_type"
        case itemId = "item_id"
        case itemName = "item_name"
        case itemExtra = "item_extra"
        case delta
        case detectedAt = "detected_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? Int.random(in: 1...Int.max)
        targetKey = try c.decodeIfPresent(String.self, forKey: .targetKey) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        scopeName = try c.decodeIfPresent(String.self, forKey: .scopeName)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType) ?? ""
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        itemName = try c.decodeIfPresent(String.self, forKey: .itemName)
        itemExtra = try c.decodeIfPresent(EventExtra.self, forKey: .itemExtra) ?? EventExtra()
        delta = try c.decodeIfPresent(Int.self, forKey: .delta)
        detectedAt = try c.decodeIfPresent(Int.self, forKey: .detectedAt) ?? 0
    }

    var detectedDate: Date { Date(timeIntervalSince1970: TimeInterval(detectedAt)) }

    /// 与 web 端 tagMap 保持一致
    var tag: String {
        switch eventType {
        case "track_added": return "新增"
        case "track_removed": return "移除"
        case "playlist_added": return "新歌单"
        case "playlist_removed": return "歌单移除"
        case "count_up": return "上升"
        case "count_down": return "下降"
        case "person_follow_added": return "关注+"
        case "person_follow_removed": return "关注-"
        case "person_fan_added": return "新粉丝"
        case "person_fan_removed": return "掉粉"
        default: return "变动"
        }
    }

    var isAdd: Bool {
        eventType == "track_added" || eventType == "playlist_added"
            || eventType == "count_up" || eventType == "person_follow_added"
            || eventType == "person_fan_added"
    }

    var detailText: String {
        var parts: [String] = []
        if let n = itemName, !n.isEmpty { parts.append(n) }
        if let artists = itemExtra.artists, !artists.isEmpty { parts.append(artists) }
        if let album = itemExtra.album, !album.isEmpty { parts.append("《\(album)》") }
        if let d = delta, d != 0 { parts.append("\(d > 0 ? "+" : "")\(d)") }
        if let before = itemExtra.before, let after = itemExtra.after {
            parts.append("\(before) → \(after)")
        }
        return parts.joined(separator: " · ")
    }
}

struct EventExtra: Codable, Sendable {
    let artists: String?
    let album: String?
    let before: Int?
    let after: Int?

    enum CodingKeys: String, CodingKey {
        case artists, album, before, after
    }

    init() {
        artists = nil; album = nil; before = nil; after = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 后端 item_extra 里 artists/album 偶尔是数组，宽松处理
        artists = Self.flexString(c, .artists)
        album = Self.flexString(c, .album)
        before = try c.decodeIfPresent(Int.self, forKey: .before)
        after = try c.decodeIfPresent(Int.self, forKey: .after)
    }

    private static func flexString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let arr = try? c.decode([String].self, forKey: key) { return arr.joined(separator: "、") }
        return nil
    }
}

// MARK: - 最近发布内容

/// `_norm_posts` 归一后的结构。早期版本可能只有 text 一个键，
/// 其余字段全部可选，缺啥都不解码失败。
struct RecentPost: Codable, Identifiable, Sendable {
    let text: String?
    let images: [String]
    let imagesTotal: Int?
    let likes: Int?
    let commentsCount: Int?
    let reposts: Int?
    let url: String?
    let video: Bool?

    // 后端快照偶尔直接塞 comments / retweet，用宽松 JSON 保留
    let retweet: String?
    let comments: [PostComment]

    var id: String { text ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case text, images, url, video, retweet, comments
        case imagesTotal = "images_total"
        case likes
        case commentsCount = "comments_count"
        case reposts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        imagesTotal = try c.decodeIfPresent(Int.self, forKey: .imagesTotal)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        commentsCount = try c.decodeIfPresent(Int.self, forKey: .commentsCount)
        reposts = try c.decodeIfPresent(Int.self, forKey: .reposts)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        video = try c.decodeIfPresent(Bool.self, forKey: .video)
        retweet = try c.decodeIfPresent(String.self, forKey: .retweet)
        comments = try c.decodeIfPresent([PostComment].self, forKey: .comments) ?? []
    }
}

struct PostComment: Codable, Identifiable, Sendable {
    let by: String?
    let text: String?
    let likes: Int?

    var id: String { (by ?? "") + (text ?? "") + String(likes ?? 0) }
}

// MARK: - 歌单明细

struct PlaylistDetail: Codable, Identifiable, Sendable {
    let targetKey: String?
    let target: String?
    let scope: String?
    let name: String
    let cover: String?
    let trackCount: Int
    let added: [String]
    let removed: [String]
    let events: [ChangeEvent]

    var id: String { scope ?? name }

    enum CodingKeys: String, CodingKey {
        case target, scope, name, cover, added, removed, events
        case targetKey = "target_key"
        case trackCount = "track_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetKey = try c.decodeIfPresent(String.self, forKey: .targetKey)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        events = try c.decodeIfPresent([ChangeEvent].self, forKey: .events) ?? []
    }
}

/// 卡片内的归档概况。区别于顶层 `archive_stats`（那个带 platform 键）：
/// 卡片里的 archive 只有 6 个计数字段，platform 是在注入卡片时由外层补的语义键，
/// 并不在对象内部。因此不能复用 TargetStats（它把 platform 设为必填）。
struct ArchiveSummary: Codable, Sendable {
    let total: Int?
    let alive: Int?
    let deleted: Int?
    let hidden: Int?
    let media: Int?
    let mediaBytes: Int?

    enum CodingKeys: String, CodingKey {
        case total, alive, deleted, hidden, media
        case mediaBytes = "media_bytes"
    }
}

// MARK: - 目标

struct MonitorTarget: Codable, Identifiable, Sendable {
    let index: Int
    let name: String
    let platform: String
    let id: String
    let enabled: Bool
    let options: TargetOptions

    var targetID: String { "\(platform):\(id)" }
    var platformEnum: Platform { Platform(rawValue: platform) ?? .unknown }

    enum CodingKeys: String, CodingKey {
        case index, name, platform, id, enabled, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        options = try c.decodeIfPresent(TargetOptions.self, forKey: .options) ?? TargetOptions()
    }
}

struct TargetOptions: Codable, Sendable {
    var people: [String]
    var maxUsers: Int?

    enum CodingKeys: String, CodingKey {
        case people
        case maxUsers = "max_users"
    }

    init(people: [String] = [], maxUsers: Int? = nil) {
        self.people = people
        self.maxUsers = maxUsers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        maxUsers = try c.decodeIfPresent(Int.self, forKey: .maxUsers)
    }
}

// MARK: - 巡检记录

struct RunRecord: Codable, Identifiable, Sendable {
    let time: String
    let status: String
    let target: String?
    let message: String?

    var id: String { "\(time)-\(target ?? "")-\(UUID().uuidString)" }
    var isOK: Bool { status == "ok" }
}

// MARK: - 服务端配置 / 状态

struct ServerConfig: Codable, Sendable {
    let pollIntervalMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case pollIntervalMinutes = "poll_interval_minutes"
    }

    init() { pollIntervalMinutes = nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMinutes)
    }
}

struct CheckStatus: Codable, Sendable {
    let running: Bool
    let manualRunning: Bool?
    let schedulerRunning: Bool?

    enum CodingKeys: String, CodingKey {
        case running
        case manualRunning = "manual_running"
        case schedulerRunning = "scheduler_running"
    }

    init() {
        running = false; manualRunning = nil; schedulerRunning = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        manualRunning = try c.decodeIfPresent(Bool.self, forKey: .manualRunning)
        schedulerRunning = try c.decodeIfPresent(Bool.self, forKey: .schedulerRunning)
    }
}

// MARK: - 登录态（采集凭证）

struct LoginStatus: Codable, Sendable {
    let netease: Bool?
    let weibo: Bool?
    let douyin: Bool?
    let xiaohongshu: Bool?
    let error: String?
    let checking: Bool?

    enum CodingKeys: String, CodingKey {
        case netease, weibo, douyin, xiaohongshu, error
        case checking = "_checking"
    }

    init() {
        netease = nil; weibo = nil; douyin = nil; xiaohongshu = nil
        error = nil; checking = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        netease = try c.decodeIfPresent(Bool.self, forKey: .netease)
        weibo = try c.decodeIfPresent(Bool.self, forKey: .weibo)
        douyin = try c.decodeIfPresent(Bool.self, forKey: .douyin)
        xiaohongshu = try c.decodeIfPresent(Bool.self, forKey: .xiaohongshu)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        checking = try c.decodeIfPresent(Bool.self, forKey: .checking)
    }

    func isLogged(_ p: Platform) -> Bool? {
        switch p {
        case .netease: return netease
        case .weibo: return weibo
        case .douyin: return douyin
        case .xiaohongshu: return xiaohongshu
        default: return nil
        }
    }
}

// MARK: - 通用响应

struct OKResponse: Codable, Sendable {
    let ok: Bool
    let message: String?
}

struct ResolveResponse: Codable, Sendable {
    let ok: Bool
    let platform: String?
    let id: String?
    let message: String?
}

struct EventsResponse: Codable, Sendable {
    let ok: Bool
    let events: [ChangeEvent]
}

// 扫码登录
struct LoginFlowStatus: Codable, Sendable {
    let state: String?
    let message: String?
    let error: String?
    let hasShot: Bool?
    let shotAt: Int?
    let elapsed: Int?

    enum CodingKeys: String, CodingKey {
        case state, message, error, elapsed
        case hasShot = "has_shot"
        case shotAt = "shot_at"
    }
}

struct LoginShotResponse: Codable, Sendable {
    let ok: Bool
    let shot: String?
    let shotAt: Int?

    enum CodingKeys: String, CodingKey {
        case ok, shot
        case shotAt = "shot_at"
    }
}
