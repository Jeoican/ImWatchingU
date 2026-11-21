import Foundation

// MARK: - 网易云歌单 / 歌曲

/// 一个网易云歌单（来自本地采集快照，不含全量歌曲）。
struct MusicPlaylist: Codable, Identifiable, Sendable {
    let targetKey: String
    let targetName: String?
    let id: String
    let name: String
    let cover: String?
    let trackCount: Int

    enum CodingKeys: String, CodingKey {
        case targetKey = "target_key"
        case targetName = "target_name"
        case id, name, cover
        case trackCount = "track_count"
    }

    init(targetKey: String, targetName: String?, id: String, name: String,
         cover: String?, trackCount: Int) {
        self.targetKey = targetKey
        self.targetName = targetName
        self.id = id
        self.name = name
        self.cover = cover
        self.trackCount = trackCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetKey = try c.decodeIfPresent(String.self, forKey: .targetKey) ?? ""
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
    }
}

struct MusicPlaylistsResponse: Codable {
    let ok: Bool
    let playlists: [MusicPlaylist]
}

/// 一首歌。name 可能为 nil（采集时未登录拿不到元数据的占位项）。
///
/// `duration` / `cover` 是后补字段：老版本后端不返回它们，
/// 所以都用 decodeIfPresent，旧数据照样能解码，界面上退化为不显示时长/封面。
struct MusicSong: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let artists: String?
    let album: String?
    /// 时长（秒）。后端已从毫秒换算，nil 表示未知。
    let duration: Int?
    /// 专辑封面原图 URL（网易云 p2/p3/p4.music.126.net）。
    let cover: String?

    var displayName: String { name ?? "未知歌曲 \(id)" }

    /// mm:ss。未知时长返回空串，避免列表里出现一排 "0:00"。
    var durationText: String {
        guard let duration, duration > 0 else { return "" }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album, duration, cover
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        artists = try c.decodeIfPresent(String.self, forKey: .artists)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
    }
}

struct MusicSongsResponse: Codable {
    let ok: Bool
    let playlist: String
    let songs: [MusicSong]
}

/// 单首歌的临时播放地址。url 为 nil 代表该歌无法播放（版权/下架/无登录态）。
struct PlayURL: Codable, Sendable {
    let url: String?
    let br: Int
    let code: Int
    let message: String?

    var isPlayable: Bool { url != nil }
}

struct MusicURLsResponse: Codable {
    let ok: Bool
    let urls: [String: PlayURL]
}

// MARK: - 歌词

/// 一行歌词。`t` 是这一行开始的时间（秒）。
struct LyricLine: Codable, Identifiable, Sendable {
    let t: Double
    let text: String
    /// 中文翻译。英文歌多数有，中文歌通常为 nil。
    let tr: String?

    var id: Double { t }
}

struct MusicLyricResponse: Codable {
    let ok: Bool
    let id: String
    let lines: [LyricLine]
    /// 后端明确告知「这首歌没有歌词」（纯音乐/下架曲），
    /// 与「请求失败但 lines 为空」区分开：前者要显示「暂无歌词」，后者该显示错误。
    let none: Bool
}
