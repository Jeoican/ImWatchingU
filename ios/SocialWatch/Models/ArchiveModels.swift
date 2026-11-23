import Foundation

// MARK: - 内容状态

/// 三态。后端目前只用 alive，deleted/hidden 在数据里是 0 条，
/// 但语义已确定，且将来会用到。
///
/// 关键设计：用 `.unknown` 兜底而不是解码失败。
/// 后端将来新增状态值时，老 App 应该降级显示而不是整个列表崩掉。
/// 这正是 web 端 `stateTag()` 的做法，保持一致。
enum ContentState: String, Codable, CaseIterable, Sendable {
    case alive
    case deleted
    case hidden
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContentState(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .alive:   return "在线"
        case .deleted: return "已删除"
        case .hidden:  return "超出窗口"
        case .unknown: return "未知"
        }
    }
}

// MARK: - 平台

enum Platform: String, Codable, Sendable {
    case weibo
    case xiaohongshu
    case douyin
    case netease
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Platform(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .weibo:       return "微博"
        case .xiaohongshu: return "小红书"
        case .douyin:      return "抖音"
        case .netease:     return "网易云"
        case .unknown:     return "其他"
        }
    }
}

// MARK: - 列表条目

/// `/api/archive/list` 的 items 元素。
///
/// 刻意**不解码** `retweet` 与 `comments`：实测 retweet 恒为 null、
/// comments 恒为 []，且两者结构从未出现过（空数组推不出字段）。
/// 猜一个类型反而会在后端将来填充真实数据时解码失败。
/// Codable 会自动忽略未声明的键，所以不解码是安全的。
struct ArchiveItem: Codable, Identifiable, Sendable, Equatable {
    let id: Int
    let postId: String
    let url: String?
    /// 来源平台（后端列表项 /api/archive/list 已透出）。老后端可能没有，宽松解码兜底为 nil。
    let platform: Platform?
    /// 来源目标键，形如 `weibo:5978197928`。用于按账号筛选与映射友好名称。
    let targetKey: String?
    let text: String
    let postedAt: Int
    let firstSeenAt: Int
    let lastSeenAt: Int
    let state: ContentState
    let stateAt: Int?
    let stateNote: String?
    let likes: Int?
    let commentsCount: Int?
    let reposts: Int?
    let imagesTotal: Int?
    let video: Bool?
    let mediaCount: Int?
    let savedCommentCount: Int?

    // 抖音个人页/作品页字段。后端尚未全部提供，全部宽松解码为 nil，
    // 老数据不会因为新增字段而失败；UI 侧没有值时显示占位而不是伪造。
    let authorName: String?
    let authorAvatar: String?
    let douyinID: String?
    let signature: String?
    let followingCount: Int?
    let followerCount: Int?
    let playCount: Int?
    let collectCount: Int?
    let shareCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case url
        case platform
        case targetKey = "target_key"
        case text
        case postedAt = "posted_at"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case state
        case stateAt = "state_at"
        case stateNote = "state_note"
        case likes
        case commentsCount = "comments_count"
        case reposts
        case imagesTotal = "images_total"
        case video
        case mediaCount = "media_count"
        case savedCommentCount = "saved_comment_count"
        case authorName = "author_name"
        case authorAvatar = "author_avatar"
        case douyinID = "douyin_id"
        case signature
        case followingCount = "following_count"
        case followerCount = "follower_count"
        case playCount = "play_count"
        case collectCount = "collect_count"
        case shareCount = "share_count"
    }

    var postedDate: Date { Date(timeIntervalSince1970: TimeInterval(postedAt)) }
    var firstSeenDate: Date { Date(timeIntervalSince1970: TimeInterval(firstSeenAt)) }
    var hasMedia: Bool { (mediaCount ?? imagesTotal ?? 0) > 0 }
    var mediaTotal: Int { mediaCount ?? imagesTotal ?? 0 }

    /// 正文清理。实测微博正文 30 条里 21 条带零宽字符（U+200B 等），
    /// web 端没处理所以看不出问题，但 App 要算行数、做截断，
    /// 这些不可见字符会让「看起来空的行」占高度。
    var cleanText: String { TextSanitizer.clean(text) }
}

// MARK: - 媒体

/// 图片档位。对应 `/api/archive/media?thumb=`
enum ThumbTier: String {
    case list     = "2"   // 200px / ~8KB，列表 56pt 格子
    case detail   = "1"   // 900px / ~105KB，详情格子与全屏首帧
    case original = "0"   // 原图 3–7MB，仅 1:1 查看时才拉
}

struct ArchiveMedia: Codable, Sendable, Equatable, Identifiable {
    let seq: Int
    let remoteUrl: String?
    /// 后端给的是 largest / orj1080 这类抓取档位，与显示无关
    let tier: String?
    /// 容器内绝对路径（形如 /app/data/archive/...）。**App 用不到**：
    /// 取图走 `?id=&seq=&thumb=`，不依赖本地路径。
    /// 声明它只是为了将来若后端去掉该字段也不会解码失败。
    let localPath: String?
    let bytes: Int?
    let width: Int?
    let height: Int?
    let cached: Bool?

    var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case seq
        case remoteUrl = "remote_url"
        case tier
        case localPath = "local_path"
        case bytes, width, height, cached
    }

    /// 宽高比。缺失时退回 3:4（微博竖图最常见），
    /// 与 web 端 `aspect-ratio:3/4` 的兜底一致。
    var aspectRatio: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 3.0 / 4.0 }
        return Double(w) / Double(h)
    }

    var isPortrait: Bool { aspectRatio < 1 }
}

// MARK: - 作者互动评论

/// `/api/archive/item` 返回的 `comments`：只存作者互动过的评论
/// （作者回复 / 作者赞过），按 web 端同样的顺序渲染。
/// 宽松解码：后端字段偶有缺失，任何一项都不该让整条详情 decode 失败。
struct ArchiveComment: Codable, Sendable {
    let authorName: String?
    let text: String?
    let likes: Int?
    let postedAt: Int?
    let byAuthor: Bool
    let likedByAuthor: Bool

    enum CodingKeys: String, CodingKey {
        case authorName = "author_name"
        case text, likes
        case postedAt = "posted_at"
        case byAuthor = "by_author"
        case likedByAuthor = "liked_by_author"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        postedAt = try c.decodeIfPresent(Int.self, forKey: .postedAt)
        byAuthor = try c.decodeIfPresent(Bool.self, forKey: .byAuthor) ?? false
        likedByAuthor = try c.decodeIfPresent(Bool.self, forKey: .likedByAuthor) ?? false
    }

    var postedDate: Date? {
        guard let postedAt, postedAt > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(postedAt))
    }
}

// MARK: - 作品音乐（抖音图文/视频都带 BGM）

/// `/api/archive/item` 返回的 `music`。抖音的图文作品本质是"图片轮播 + 音乐"，
/// 音乐是作品的一部分，不是外挂——所以 feed 要能自动播它。
/// 宽松解码：平台有些作品只给歌名没有播放直链，任何字段缺失都不能让详情 decode 失败。
struct ArchiveMusic: Codable, Sendable {
    let id: String?
    let title: String?
    let author: String?
    let album: String?
    let duration: Int?
    let coverURL: String?
    let cached: Bool?
    let bytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, author, album, duration
        case coverURL = "cover_url"
        case cached, bytes
    }

    /// feed 转盘上显示的歌名。抖音"创作的原声"这类标题很长，展示时截断到 18 字。
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 18 { return t }
        return String(t.prefix(18)) + "…"
    }

    var displayAuthor: String {
        let a = (author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "抖音音乐" : a
    }
}

// MARK: - 详情

struct ArchiveDetail: Codable, Sendable {
    let id: Int
    let postId: String
    let url: String?
    let text: String
    let textRaw: String?
    let authorName: String?
    /// 作者头像 URL（后端从账号快照取），可能为 nil → 降级显示昵称首字。
    let authorAvatar: String?
    /// 抖音账号信息。后端尚未全部提供，宽松解码为 nil。
    let douyinID: String?
    let signature: String?
    let followingCount: Int?
    let followerCount: Int?
    let playCount: Int?
    let collectCount: Int?
    let shareCount: Int?
    let targetKey: String?
    let platform: Platform?
    let postedAt: Int
    let firstSeenAt: Int
    let lastSeenAt: Int
    let state: ContentState
    let stateAt: Int?
    let stateNote: String?
    let likes: Int?
    let commentsCount: Int?
    let reposts: Int?
    let imagesTotal: Int?
    let video: Bool?
    let media: [ArchiveMedia]
    /// 作品 BGM（抖音图文也有）。老后端可能没有该字段，宽松兜底为 nil。
    let music: ArchiveMusic?
    /// 作者互动过的评论（作者回复 / 作者赞过）。老后端可能没有该字段，宽松兜底为空。
    let comments: [ArchiveComment]
    /// 转发原文（微博）。后端字段是 retweet_text，可能缺失。
    let retweetText: String?

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case url, text
        case textRaw = "text_raw"
        case authorName = "author_name"
        case authorAvatar = "author_avatar"
        case douyinID = "douyin_id"
        case signature
        case followingCount = "following_count"
        case followerCount = "follower_count"
        case playCount = "play_count"
        case collectCount = "collect_count"
        case shareCount = "share_count"
        case targetKey = "target_key"
        case platform
        case postedAt = "posted_at"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case state
        case stateAt = "state_at"
        case stateNote = "state_note"
        case likes
        case commentsCount = "comments_count"
        case reposts
        case imagesTotal = "images_total"
        case video, media
        case music
        case comments
        case retweetText = "retweet_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        postId = try c.decodeIfPresent(String.self, forKey: .postId) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        textRaw = try c.decodeIfPresent(String.self, forKey: .textRaw)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        authorAvatar = try c.decodeIfPresent(String.self, forKey: .authorAvatar)
        douyinID = try c.decodeIfPresent(String.self, forKey: .douyinID)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        followingCount = try c.decodeIfPresent(Int.self, forKey: .followingCount)
        followerCount = try c.decodeIfPresent(Int.self, forKey: .followerCount)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        collectCount = try c.decodeIfPresent(Int.self, forKey: .collectCount)
        shareCount = try c.decodeIfPresent(Int.self, forKey: .shareCount)
        targetKey = try c.decodeIfPresent(String.self, forKey: .targetKey)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        postedAt = try c.decodeIfPresent(Int.self, forKey: .postedAt) ?? 0
        firstSeenAt = try c.decodeIfPresent(Int.self, forKey: .firstSeenAt) ?? 0
        lastSeenAt = try c.decodeIfPresent(Int.self, forKey: .lastSeenAt) ?? 0
        state = try c.decodeIfPresent(ContentState.self, forKey: .state) ?? .unknown
        stateAt = try c.decodeIfPresent(Int.self, forKey: .stateAt)
        stateNote = try c.decodeIfPresent(String.self, forKey: .stateNote)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        commentsCount = try c.decodeIfPresent(Int.self, forKey: .commentsCount)
        reposts = try c.decodeIfPresent(Int.self, forKey: .reposts)
        imagesTotal = try c.decodeIfPresent(Int.self, forKey: .imagesTotal)
        video = try c.decodeIfPresent(Bool.self, forKey: .video)
        media = try c.decodeIfPresent([ArchiveMedia].self, forKey: .media) ?? []
        music = try c.decodeIfPresent(ArchiveMusic.self, forKey: .music)
        comments = try c.decodeIfPresent([ArchiveComment].self, forKey: .comments) ?? []
        retweetText = try c.decodeIfPresent(String.self, forKey: .retweetText)
    }

    var postedDate: Date { Date(timeIntervalSince1970: TimeInterval(postedAt)) }
    var firstSeenDate: Date { Date(timeIntervalSince1970: TimeInterval(firstSeenAt)) }
    var cleanText: String { TextSanitizer.clean(text) }
}

// MARK: - 统计

/// `/api/archive/list` 的 stats，键是 `平台:id` 形式的 target key。
struct TargetStats: Codable, Sendable {
    let platform: String
    let total: Int
    let alive: Int
    let deleted: Int
    let hidden: Int
    let media: Int
    let mediaBytes: Int

    enum CodingKeys: String, CodingKey {
        case platform, total, alive, deleted, hidden, media
        case mediaBytes = "media_bytes"
    }

    var mediaSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(mediaBytes), countStyle: .file)
    }
}

// MARK: - 响应包装

struct ArchiveListResponse: Codable, Sendable {
    let ok: Bool
    let items: [ArchiveItem]
    /// 复合游标，形如 `"1782550673:2"`。必须原样传回，不能拆开重拼：
    /// posted_at 相同的多条内容靠 id 才能定序，只用时间戳会漏条。
    let nextCursor: String?
    let hasMore: Bool
    let stats: [String: TargetStats]

    enum CodingKeys: String, CodingKey {
        case ok, items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case stats
    }
}

struct ArchiveDetailResponse: Codable, Sendable {
    let ok: Bool
    let item: ArchiveDetail
}

// MARK: - 文本清理

enum TextSanitizer {
    /// 去掉零宽字符与多余空白。
    ///
    /// 为什么需要：抓下来的微博正文带 U+200B（零宽空格），实测 30 条里 21 条有。
    /// SwiftUI 的 Text 会照常渲染它（不可见），但一旦要做
    /// 行数估算、截断、搜索高亮，这些字符会算出错误的位置。
    static func clean(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060:  // 零宽空格/换行符/BOM/word joiner
                continue
            default:
                out.append(scalar)
            }
        }
        let joined = String(out)
        // 行尾空白清掉，连续空行压成一行
        let lines = joined
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
