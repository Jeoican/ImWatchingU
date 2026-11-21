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
struct MusicSong: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let artists: String?
    let album: String?

    var displayName: String { name ?? "未知歌曲 \(id)" }

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        artists = try c.decodeIfPresent(String.self, forKey: .artists)
        album = try c.decodeIfPresent(String.self, forKey: .album)
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
