import SwiftUI

// MARK: - 歌单列表

/// 「我的歌单」入口页：列出网易云账号下的全部歌单。
/// 入口放在内容库的「网易云」标签下，不单独占一个 Tab。
struct PlaylistListView: View {
    @State private var playlists: [MusicPlaylist] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14)).foregroundColor(.red)
                }
            }
            if !isLoading && playlists.isEmpty && errorText == nil {
                Section {
                    Text("还没有采集到歌单，先跑一次巡检吧")
                        .font(.system(size: 14)).foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(playlists) { pl in
                    NavigationLink(destination: SongListView(playlist: pl)) {
                        MusicPlaylistRow(playlist: pl)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("我的歌单")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { load() }
        .task {
            if let cached = DataCache.load("music:playlists", as: [MusicPlaylist].self,
                                           maxAge: 30 * 24 * 3600) {
                playlists = cached
            }
            if playlists.isEmpty { load() }
        }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        Task {
            do {
                let list = try await APIClient.shared.musicPlaylists()
                await MainActor.run { playlists = list; isLoading = false }
                DataCache.save("music:playlists", value: list)
            } catch let e as APIError {
                await MainActor.run {
                    let host = CredentialStore.shared.load()?.normalizedBaseURL?.absoluteString ?? "未配置"
                    // 有缓存时保留旧数据，不弹错误遮住列表
                    if playlists.isEmpty {
                        errorText = "\(e.errorDescription ?? "加载失败")\n服务器：\(host)"
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run { if playlists.isEmpty { errorText = error.localizedDescription }; isLoading = false }
            }
        }
    }
}

struct MusicPlaylistRow: View {
    let playlist: MusicPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ProxyImage(url: playlist.cover, placeholderText: playlist.name)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text("\(playlist.trackCount) 首")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 歌曲列表

/// 单个歌单的歌曲列表。点任意一首即从该首开始播放整个歌单。
struct SongListView: View {
    let playlist: MusicPlaylist
    @ObservedObject private var player = AudioPlayer.shared
    @State private var songs: [MusicSong] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14)).foregroundColor(.red)
                }
            }
            Section {
                Button {
                    if !songs.isEmpty { player.play(queue: songs, at: 0, playlistTitle: playlist.name) }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("播放全部（\(songs.count) 首）")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                }
                .disabled(songs.isEmpty)
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    Button {
                        player.play(queue: songs, at: idx, playlistTitle: playlist.name)
                    } label: {
                        SongRow(song: song,
                                number: idx + 1,
                                isCurrent: player.currentIndex == idx && !player.queue.isEmpty)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { load() }
        .task {
            let key = "music:songs:\(playlist.id)"
            if let cached = DataCache.load(key, as: [MusicSong].self,
                                           maxAge: 30 * 24 * 3600) {
                songs = cached
            }
            if songs.isEmpty {
                let list = await loadSongs()
                #if DEBUG
                if ProcessInfo.processInfo.environment["SW_DEBUG_PLAY"] == "1", !list.isEmpty {
                    player.play(queue: list, at: 0, playlistTitle: playlist.name)
                }
                #endif
            }
        }
    }

    private func load() {
        Task { await loadSongs() }
    }

    @discardableResult
    private func loadSongs() async -> [MusicSong] {
        guard !isLoading else { return [] }
        isLoading = true
        errorText = nil
        do {
            let list = try await APIClient.shared.musicSongs(playlist: playlist.id,
                                                              target: playlist.targetKey)
            await MainActor.run { songs = list; isLoading = false }
            DataCache.save("music:songs:\(playlist.id)", value: list)
            return list
        } catch let e as APIError {
            await MainActor.run { if songs.isEmpty { errorText = e.errorDescription }; isLoading = false }
        } catch {
            await MainActor.run { if songs.isEmpty { errorText = error.localizedDescription }; isLoading = false }
        }
        return []
    }
}

private struct SongRow: View {
    let song: MusicSong
    let number: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13))
                .foregroundColor(isCurrent ? Color(red: 0.82, green: 0.28, blue: 0.22) : .secondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.displayName)
                    .font(.system(size: 15))
                    .foregroundColor(isCurrent ? Color(red: 0.82, green: 0.28, blue: 0.22) : .primary)
                    .lineLimit(1)
                if let artists = song.artists, !artists.isEmpty {
                    Text(artists)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - 迷你播放条

/// 贴在 TabBar 上方的迷你播放器。只要有歌在队列里就显示，点它展开全屏。
struct MiniPlayerBar: View {
    @ObservedObject private var player = AudioPlayer.shared
    @State private var showFullPlayer = false

    var body: some View {
        Group {
            if player.currentSong != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .frame(width: 2, height: 2)
                            .opacity(player.isLoading ? 1 : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentSong?.displayName ?? "")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(player.currentSong?.artists ?? "")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                        }
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { showFullPlayer = true }
                    // 细进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color(.systemGray5).frame(height: 2)
                            Color(red: 0.82, green: 0.28, blue: 0.22)
                                .frame(width: geo.size.width * CGFloat(player.progress), height: 2)
                        }
                    }
                    .frame(height: 2)
                }
                .background(Color.white)
                .overlay(Rectangle().fill(Color(.systemGray5)).frame(height: 0.5), alignment: .top)
                .sheet(isPresented: $showFullPlayer) { FullPlayerView().environmentObject(AudioPlayer.shared) }
            }
        }
    }
}

// MARK: - 全屏播放器

struct FullPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button { presentationMode.wrappedValue.dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 20))
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("正在播放").font(.system(size: 12)).foregroundColor(.secondary)
                    Text(player.playlistTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                Spacer()
                Button { player.stop(); presentationMode.wrappedValue.dismiss() } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 18)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            if let song = player.currentSong {
                VStack(spacing: 8) {
                    Text(song.displayName)
                        .font(.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(song.artists ?? "")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            if let msg = player.errorMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { player.progress },
                    set: { player.progress = $0 }
                ))
                .padding(.horizontal, 24)
                .disabled(player.duration <= 0)
                HStack {
                    Text(formatTime(player.currentTime)).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(player.duration)).font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 26)
            }

            HStack(spacing: 40) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 28))
                }
                Button { player.togglePlayPause() } label: {
                    if player.isLoading {
                        ProgressView().frame(width: 56, height: 56)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 56, height: 56)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 28))
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(red: 0.98, green: 0.98, blue: 0.97))
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
