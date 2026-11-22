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
            // 始终后台回源刷新，不要只在缓存为空时才拉：
            // 老版本缓存里没有 cover/duration 字段，命中旧缓存会让封面永远不显示。
            // 先展示缓存（秒开），再静默刷新补上新字段。
            _ = await loadSongs()
            #if DEBUG
            // 自动化验证：SW_DEBUG_PLAY=1 直接起播。
            // 必须放在 if 外面 —— 命中缓存时不会进上面的分支，
            // 藏在里面就永远触发不了（这个坑踩过一次）。
            if ProcessInfo.processInfo.environment["SW_DEBUG_PLAY"] == "1",
               !songs.isEmpty, player.currentSong == nil {
                player.play(queue: songs, at: 0, playlistTitle: playlist.name)
            }
            #endif
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
            ZStack {
                if isCurrent {
                    // 正在播：序号位置换成小喇叭，比数字更直观
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                } else {
                    Text("\(number)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 22)

            // 专辑封面：拿到 cover 才显示，否则用音符占位，不留空洞
            AlbumArt(url: song.cover, size: 44, corner: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayName)
                    .font(.system(size: 15))
                    .foregroundColor(isCurrent ? Color(red: 0.82, green: 0.28, blue: 0.22) : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let artists = song.artists, !artists.isEmpty {
                        Text(artists)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if !song.durationText.isEmpty {
                        Text(song.durationText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 专辑封面

/// 统一的专辑封面视图：有 URL 走 /api/img 代理，没有则音符占位。
/// 单抽出来是因为歌曲列表、悬浮球、全屏播放器三处都要用，
/// 尺寸与圆角不同，但加载/降级逻辑必须一致。
struct AlbumArt: View {
    let url: String?
    let size: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            if let url, !url.isEmpty {
                ProxyImage(url: url, placeholderText: "", circular: false)
            } else {
                ZStack {
                    Color(red: 0.94, green: 0.94, blue: 0.93)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.58))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - 迷你播放球

/// 右下角的小悬浮球播放器。
///
/// 演进过程（三次迭代，前两次都是被用户打回才改的）
/// -------------------------------------------------
/// 1.0 整条横条 → 横贯屏宽，压在内容上太重；
/// 2.0 白底圆球 + 播放图标 → 不遮挡了，但信息量为零，用户说"能不能更丰满"；
/// 3.0 现在这版 → 球体本身就是专辑封面，外圈套进度环，
///     播放/暂停叠在封面上（未播放时显示，播放时淡出以免挡封面）。
/// 点球进全屏播放器（大封面 + 滚动歌词 + 完整控制）。
///
/// 尺寸 58pt：比之前的 56 略大，是为了让封面能看清；
/// 仍然只占右下角一点点，不会盖住 TabBar 的三个 Tab。
struct MiniPlayerBubble: View {
    @ObservedObject private var player = AudioPlayer.shared
    @State private var showFullPlayer = false

    private let diameter: CGFloat = 58

    var body: some View {
        Group {
            if let song = player.currentSong {
                Button {
                    showFullPlayer = true
                } label: {
                    ZStack {
                        // ① 外圈进度环（灰底 + 主题色进度）
                        Circle()
                            .stroke(Color(.systemGray5), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(min(max(player.progress, 0), 1)))
                            .stroke(Color(red: 0.82, green: 0.28, blue: 0.22),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))

                        // ② 球体 = 专辑封面，圆形裁切，留 2pt 让出进度环
                        Group {
                            if let cover = song.cover, !cover.isEmpty {
                                ProxyImage(url: cover, placeholderText: "", circular: true)
                            } else {
                                ZStack {
                                    Color(red: 0.96, green: 0.95, blue: 0.93)
                                    Image(systemName: "music.note")
                                        .font(.system(size: 20))
                                        .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                                }
                            }
                        }
                        .frame(width: diameter - 7, height: diameter - 7)
                        .clipShape(Circle())

                        // ③ 状态层：加载中转圈；播放中不挡封面，暂停时盖一层暗罩 + 播放键
                        if player.isLoading {
                            Circle()
                                .fill(Color.black.opacity(0.35))
                                .frame(width: diameter - 7, height: diameter - 7)
                            ProgressView().tint(.white)
                        } else if !player.isPlaying {
                            Circle()
                                .fill(Color.black.opacity(0.30))
                                .frame(width: diameter - 7, height: diameter - 7)
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                    // ④ 播放模式角标：不是顺序播放时，在右下角标一个小图标。
                    // 迷你态也要能看出「在随机」或「单曲循环」，否则用户进全屏前
                    // 根本不知道下一首是怎么来的。
                    .overlay(alignment: .bottomTrailing) {
                        if player.playMode != .sequential {
                            Image(systemName: player.playMode.icon)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color(red: 0.82, green: 0.28, blue: 0.22)))
                                .offset(x: 2, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                // 长按快捷暂停/播放，不必进全屏
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        player.togglePlayPause()
                    }
                )
                .accessibilityLabel(accessibilityText(song))
                .sheet(isPresented: $showFullPlayer) {
                    FullPlayerView().environmentObject(AudioPlayer.shared)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                #if DEBUG
                // 自动化验证通道：模拟器无法注入点击，靠这个 env 直接弹全屏播放器，
                // 用于截图核对大封面 + 滚动歌词。Release 不含此代码。
                .onAppear {
                    if ProcessInfo.processInfo.environment["SW_DEBUG_FULLPLAYER"] == "1" {
                        showFullPlayer = true
                    }
                }
                #endif
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentSong != nil)
    }

    /// 读屏软件念出来的内容：光有"播放/暂停"对看不见封面的人毫无信息量
    private func accessibilityText(_ song: MusicSong) -> String {
        let title = song.displayName
        let artist = song.artists.map { "，\($0)" } ?? ""
        return "\(player.isPlaying ? "正在播放" : "已暂停")：\(title)\(artist)"
    }
}

/// 旧版整条迷你播放器。已由 MiniPlayerBubble 取代，保留代码便于对照回滚。
/// 当前无任何视图引用它（避免 dead code 编译告警不影响功能）。
private struct MiniPlayerBar: View {
    @ObservedObject private var player = AudioPlayer.shared
    @State private var showFullPlayer = false

    var body: some View {
        Group {
            if player.currentSong != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
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
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { showFullPlayer = true }
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
                .sheet(isPresented: $showFullPlayer) { FullPlayerView().environmentObject(AudioPlayer.shared) }
            }
        }
    }
}

// MARK: - 全屏播放器

/// 全屏播放器 —— 视觉结构参照 Beans Music 的经典皮肤，底层完全绑定本项目 AudioPlayer。
///
/// 为什么用「最外层 GeometryReader + ZStack 分层 + 控制区钉底」而不是整页 ScrollView：
///   · 控制区用确定的 contentH 预留空间，永远不会被内容挤压（上一版控件消失的根因）；
///   · SeekBar 的 GeometryReader 位于最外层 Geo 内、且不在 ScrollView 里 —— 这是关键，
///     GeometryReader 嵌进 ScrollView 会让 SwiftUI 的 VStack 高度计算塌缩，整行控件消失；
///   · 封面页 / 歌词页放在同一 ZStack 里做淡入切换，避免切换时布局重算。
///
/// 交互对齐主流播放器：点封面进整页歌词、点歌词行跳转、左右两端模式/队列、主控制居中。
struct FullPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var showQueue = false
    /// true → 整页滚动歌词；false → 大封面（点封面进入，网易云 / Beans 的经典交互）
    #if DEBUG
    // 自动化验证：模拟器无法注入点击，用环境变量决定初始进入歌词页
    @State private var showingLyrics = ProcessInfo.processInfo.environment["SW_DEBUG_LYRICS"] == "1"
    #else
    @State private var showingLyrics = false
    #endif

    /// 主题红：进度、主播放键、歌词高亮统一用色，和 App 其它页保持一致
    private let accent = Color(red: 0.82, green: 0.28, blue: 0.22)

    var body: some View {
        ZStack {
            background

            // 用 ScrollView 承载、子视图按自然高度排布 —— 这是上一版验证过稳定的机制。
            // 不再用 GeometryReader 分层：在那个 sheet 里外层 VStack 的居中对齐
            // 会把设了固定 width 的子视图推到右侧（实测内容区/控制组整体右偏）。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    headerBar
                        .padding(.top, 4)
                    ZStack {
                        if showingLyrics {
                            lyricsPage
                        } else {
                            coverPage
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: showingLyrics)
                    controlDeck
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(edges: .bottom)
        // sheet 挂最外层：挂子视图上会让该子视图的按钮不渲染（踩过）
        .sheet(isPresented: $showQueue) {
            PlayQueueSheet().environmentObject(player)
        }
        #if DEBUG
        .background(GeometryReader { g in
            Color.clear.onAppear {
                NSLog("[SW] fullPlayer screen=%@ frame=%@",
                      NSCoder.string(for: UIScreen.main.bounds),
                      NSCoder.string(for: g.frame(in: .global)))
            }
        })
        #endif
    }

    // MARK: 背景 —— 封面毛玻璃 + 主题渐变 + 可读性遮罩（Beans 的多层背景思路）

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let cover = player.currentSong?.cover, !cover.isEmpty {
                ProxyImage(url: cover, placeholderText: "")
                    .scaleEffect(1.35)
                    .blur(radius: 44)
                    .opacity(colorScheme == .dark ? 0.32 : 0.26)
            }
            // 主题色上下渐变，把整页色调拉到专辑氛围
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.22 : 0.14),
                         Color.clear,
                         accent.opacity(colorScheme == .dark ? 0.18 : 0.10)],
                startPoint: .top, endPoint: .bottom
            )
            // 遮罩：浅色压白、深色压黑，保证文字/按钮始终可读
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.10), Color.black.opacity(0.42)]
                    : [Color.white.opacity(0.10), Color.white.opacity(0.36)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: 顶部栏

    private var headerBar: some View {
        HStack(spacing: 0) {
            // frame 必须加在 Button 外部、label 保持纯 Image：
            // 之前把 frame/background 加在 label(Image) 内部，sheet+毛玻璃下两个按钮整块不渲染。
            // 不加 Spacer：ScrollView 的宽松宽度提案下，Spacer 会把两端按钮推到屏幕外
            // （表现就是"中间文字在、两侧按钮消失"）。紧凑居中反而自然接近两端。
            Button { presentationMode.wrappedValue.dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: 44, height: 44)

            VStack(spacing: 2) {
                Text(player.isLoading ? "加载中…" : (player.isPlaying ? "正在播放" : "已暂停"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text(player.playlistTitle.isEmpty ? "正在播放" : player.playlistTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 240)

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("播放队列")
        }
        .padding(.horizontal, 20)
        .foregroundColor(.primary)
    }

    // MARK: 封面页（点击进歌词）

    private var coverPage: some View {
        let side: CGFloat = 300
        return VStack(spacing: 14) {
            Spacer(minLength: 0)

            Button { withAnimation(.easeInOut(duration: 0.22)) { showingLyrics = true } } label: {
                ZStack {
                    // 封面背后的柔光，令大封面从背景里"浮"出来
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.28 : 0.20))
                        .frame(width: side * 1.12, height: side * 1.12)
                        .blur(radius: 26)
                    if let song = player.currentSong {
                        AlbumArt(url: song.cover, size: side, corner: 18)
                            .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
                    } else {
                        AlbumArt(url: nil, size: side, corner: 18)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 5) {
                Text(player.currentSong?.displayName ?? "未在播放")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                Text(player.currentSong?.artists ?? "未知歌手")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            // 歌词预览一行：唱到哪句一眼可见，也暗示"点封面能看全词"
            if !player.lyrics.isEmpty,
               player.currentLyricIndex >= 0,
               player.currentLyricIndex < player.lyrics.count {
                Text(player.lyrics[player.currentLyricIndex].text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 40)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    // MARK: 歌词页

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            // 返回封面的入口：居中按钮。
            // 不用 Spacer 撑开（ScrollView 宽松提案下会把两端内容推出屏幕）。
            Button { withAnimation(.easeInOut(duration: 0.22)) { showingLyrics = false } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("收起歌词")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)

            LyricsView(player: player)
                .frame(height: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: 底部控制区

    private var controlDeck: some View {
        VStack(spacing: 0) {
            seekBar
                .padding(.horizontal, 24)
                .padding(.top, 4)

            // 主控制组单独居中（不与其它视图共享 HStack），避免 Spacer 挤压错位。
            mainControls
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            // 次要操作行：模式 + 队列，各自带文字，与上一版验证过的机制一致。
            HStack(spacing: 56) {
                modeButton
                queueButton
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            if let msg = player.errorMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
            }
        }
    }

    /// 自绘进度条（不用系统 Slider）：轨道 + 主题色填充 + 圆点 + 拖拽 seek。
    /// 关键：不用 GeometryReader —— 它在 ScrollView 里会让整行塌缩为 0 而消失（踩过）。
    /// 用固定内容宽度按比例绘制，各机型差异可接受。
    private var seekBar: some View {
        let trackW: CGFloat = 320
        let p = CGFloat(min(max(player.progress, 0), 1))
        return VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16)).frame(width: trackW, height: 4)
                Capsule().fill(accent).frame(width: max(0, trackW * p), height: 4)
                Circle().fill(accent)
                    .frame(width: 12, height: 12)
                    .offset(x: trackW * p - 6)
            }
            .frame(width: trackW, height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard player.duration > 0 else { return }
                    player.progress = Double(min(max(v.location.x / trackW, 0), 1))
                })
            HStack {
                Text(formatTime(player.currentTime))
                Spacer(minLength: 0)
                Text(formatTime(player.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(width: trackW)
        }
        .frame(maxWidth: .infinity)
    }

    private var mainControls: some View {
        HStack(spacing: 30) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24))
                    .frame(width: 50, height: 50)
            }
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(accent).frame(width: 66, height: 66)
                    if player.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .shadow(color: accent.opacity(0.40), radius: 14, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
                    .frame(width: 50, height: 50)
            }
        }
        .foregroundColor(.primary)
    }

    /// 播放模式：顺序 / 随机 / 单曲循环，点一下循环切换
    private var modeButton: some View {
        Button { player.cyclePlayMode() } label: {
            VStack(spacing: 3) {
                Image(systemName: player.playMode.icon)
                    .font(.system(size: 17, weight: .medium))
                Text(player.playMode.title)
                    .font(.system(size: 9))
            }
            .foregroundColor(player.playMode == .sequential ? .secondary : accent)
            .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playMode.title)
    }

    private var queueButton: some View {
        Button { showQueue = true } label: {
            VStack(spacing: 3) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .medium))
                Text("队列")
                    .font(.system(size: 9))
            }
            .foregroundColor(.secondary)
            .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放队列")
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 播放队列

/// 播放队列面板：列出当前歌单所有歌，点一行直接切过去。
///
/// 用户要的是「随机/顺序播放」之外还能**看得见**队列在放什么 ——
/// 否则随机模式下一首是什么完全不可预期。
struct PlayQueueSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { idx, song in
                        Button {
                            player.play(at: idx)
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: idx == player.currentIndex
                                      ? "speaker.wave.2.fill" : "music.note")
                                    .font(.system(size: 13))
                                    .foregroundColor(idx == player.currentIndex
                                                     ? Color(red: 0.82, green: 0.28, blue: 0.22)
                                                     : Color.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.displayName)
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                    if let a = song.artists, !a.isEmpty {
                                        Text(a)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if idx == player.currentIndex {
                                    Text(player.isPlaying ? "播放中" : "暂停")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("播放队列（\(player.queue.count) 首）")
                        Spacer()
                        Text(player.playMode.title)
                            .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.22))
                    }
                }
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        player.stop()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: - 滚动歌词

/// 逐行滚动、当前行高亮居中的歌词视图。
///
/// 三种状态必须区分（缺一个都会让界面"看起来卡住了"）：
///   · lyricLoading  → 转圈（正在拉）
///   · lyricAbsent   → 「暂无歌词」（后端确认没有，别再转）
///   · lines 非空     → 滚动列表
private struct LyricsView: View {
    @ObservedObject var player: AudioPlayer

    /// 用户手动滚动后暂停自动跟随的截止时间。
    /// 用时间戳而不是 Bool：用户滑一下，3 秒内不抢，3 秒后自动恢复跟随，
    /// 不需要用户再做任何动作（比"手动关掉自动滚动"的开关更省心）。
    @State private var followResumeAt: Date = .distantPast

    var body: some View {
        Group {
            if player.lyricLoading {
                ProgressView().tint(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if player.lyricAbsent && player.lyrics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 26))
                        .foregroundColor(Color.secondary.opacity(0.5))
                    Text("暂无歌词")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 为什么要套 GeometryReader 拿显式宽度：
                // 竖直 ScrollView 在 iOS 16 上对内容的宽度提案并不总是等于自身宽度，
                // 内容一旦按「最宽那一行」收缩，整列就会贴在左边 ——
                // 表现就是「歌词看着不居中」。给死宽度最稳，一行代码换掉一类玄学。
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 16) {
                                // 上下各留一块空白，让首尾行也能滚到正中
                                Color.clear.frame(height: 90)
                                ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { i, line in
                                    lyricRow(line, isCurrent: i == player.currentLyricIndex, width: geo.size.width)
                                        .id(i)
                                }
                                Color.clear.frame(height: 120)
                            }
                            .frame(width: geo.size.width)
                        }
                        .frame(width: geo.size.width)
                        .onChange(of: player.currentLyricIndex) { idx in
                            guard Date() >= followResumeAt else { return }
                            guard idx >= 0, idx < player.lyrics.count else { return }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                        // 用户一开始拖就暂停跟随，松手后 3 秒恢复
                        .simultaneousGesture(
                            DragGesture().onChanged { _ in
                                followResumeAt = Date().addingTimeInterval(3)
                            }
                        )
                        .onAppear {
                            // 进来时立即对齐到当前行（不用等下一次进度回调）
                            if player.currentLyricIndex >= 0 {
                                proxy.scrollTo(player.currentLyricIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func lyricRow(_ line: LyricLine, isCurrent: Bool, width: CGFloat) -> some View {
        let size: CGFloat = isCurrent ? 17 : 15
        return VStack(spacing: 3) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: size, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(isCurrent ? .primary : Color.primary.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let tr = line.tr, !tr.isEmpty {
                Text(tr)
                    .font(.system(size: isCurrent ? 13 : 12))
                    .foregroundColor(isCurrent ? Color(red: 0.82, green: 0.28, blue: 0.22).opacity(0.85)
                                               : Color.secondary.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        // 关键：整行必须撑满「已知的屏宽」，不能是 maxWidth: .infinity。
        // 竖直 ScrollView 对内容宽度的提案在 iOS 16 上并不总等于自身宽度，
        // 内容一旦按最宽的某一行收缩，整列就会贴左 —— 看上去就是「歌词不居中」。
        // 传死宽度后，每行都在同一把尺子上居中，长短行左边缘对齐。
        .frame(width: width)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}
