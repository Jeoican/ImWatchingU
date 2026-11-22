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

/// 全屏播放器：模糊封面背景 + 大专辑图 + 逐行滚动歌词。
///
/// 版式选择的理由
/// --------------
/// 网易云/Apple Music 的经典布局是「封面 + 歌词」，两者都要：
///   · 封面给的是"这首歌是什么"的直观识别
///   · 歌词给的是"唱到哪了"的陪伴感
/// 屏幕高度有限，所以上面封面占 38% 左右，中间歌词占剩余空间，
/// 底部固定放进度条与控制键 —— 控制键不能跟着歌词滚走。
///
/// 背景不做纯色而用封面模糊放大：
/// 纯色（0.98 米白）在大封面旁边会显得干、像未完成的页面；
/// 封面取色的模糊底把整页色调拉齐，视觉上"这张专辑就是这个颜色"。
struct FullPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.presentationMode) private var presentationMode
    /// 是否展开播放队列
    @State private var showQueue = false

    var body: some View {
        ZStack {
            background
            // 用 Vertical ScrollView 承载，所有子块按「自然高度」自上而下排布。
            //
            // 教训：不要用 VStack + Spacer + .frame(maxHeight:.infinity) 去
            // 「自适应分配」高度。实测 SwiftUI 会把中间几块（进度条、控制区）
            // 压到远小于内容所需，Slider / 模式按钮 / 时间文字被挤出可见区 ——
            // 底色在、控件整块消失，且 .frame(height:) / .fixedSize 都救不回来。
            // ScrollView 不做这种压缩，子视图各按自身尺寸渲染，最稳。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                    cover
                        .padding(.horizontal, 56)
                        .padding(.top, 18)
                    songInfo
                        .padding(.top, 16)
                    progressBar
                        .padding(.top, 10)
                    controls
                        .padding(.top, 6)
                    lyricsArea
                        .frame(height: 300)
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(edges: .bottom)
        // sheet 必须挂在**最外层**视图上。挂在 header 这种子视图上时，
        // SwiftUI 会把它当作该子视图的呈现控制器，实测会让 header 里的
        // 按钮整个不渲染（队列按钮凭空消失）。
        .sheet(isPresented: $showQueue) {
            PlayQueueSheet()
                .environmentObject(player)
        }
        #if DEBUG
        .background(GeometryReader { g in
            Color.clear.onAppear {
                NSLog("[SW] fullPlayer screen=%@ top=%@",
                      NSCoder.string(for: UIScreen.main.bounds),
                      NSCoder.string(for: g.frame(in: .global)))
            }
        })
        #endif
    }

    // MARK: 背景
    private var background: some View {
        ZStack {
            Color(red: 0.98, green: 0.98, blue: 0.97)
            if let cover = player.currentSong?.cover, !cover.isEmpty {
                ProxyImage(url: cover, placeholderText: "")
                    .blur(radius: 60)
                    .opacity(0.32)
                    .overlay(Color(red: 0.98, green: 0.98, blue: 0.97).opacity(0.18))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 0) {
            Button { presentationMode.wrappedValue.dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: 44, height: 44)

            // 中间标题：**必须限宽**，否则长歌单名会把 Spacer 挤没，
            // 两端的按钮就被推出屏幕外（实测：顶栏按钮整个看不见）。
            VStack(spacing: 2) {
                Text("正在播放").font(.system(size: 11)).foregroundColor(.secondary)
                Text(player.playlistTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 240)

            Button { showQueue.toggle() } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("播放队列")
        }
        .foregroundColor(.primary)
    }

    // MARK: 专辑封面

    /// 封面保持 1:1 正方形，宽度撑满可用宽度，但用 maxWidth 限死上限，
    /// 这样在矮屏上也不会把下面的进度条/控制区挤没。
    private var cover: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 320)
            ZStack {
                if let song = player.currentSong {
                    AlbumArt(url: song.cover, size: side, corner: 16)
                        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
                } else {
                    AlbumArt(url: nil, size: side, corner: 16)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
    }

    // MARK: 歌名 / 歌手

    /// 歌名、歌手、进度、控制区统一左右留白 24pt 并整体居中，
    /// 与封面、歌词的中轴对齐 —— 这一块之前贴着边，是"整页不协调"的主因。
    private var songInfo: some View {
        VStack(spacing: 3) {
            if let song = player.currentSong {
                Text(song.displayName)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                Text(song.artists ?? "未知歌手")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: 进度

    /// 进度条自己画（不用系统 Slider）：轨道 + 已播填充 + 拖动手势 seek。
    /// 系统 Slider 在这个 sheet + 模糊背景的组合下实测不渲染，自定义最可靠。
    /// 进度条自己画（不用系统 Slider）：轨道 + 已播填充 + 拖动手势 seek。
    private var progressBar: some View {
        // 不用 GeometryReader：它在 ScrollView 里会让 VStack 高度计算异常，
        // 导致整行（含时间文字）塌缩为 0 而不可见。用固定内容宽度按比例绘制。
        let trackW: CGFloat = 320
        let p = CGFloat(min(max(player.progress, 0), 1))
        return VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray4)).frame(width: trackW, height: 4)
                Capsule().fill(Color(red: 0.82, green: 0.28, blue: 0.22))
                    .frame(width: max(0, trackW * p), height: 4)
                Circle().fill(Color(red: 0.82, green: 0.28, blue: 0.22))
                    .frame(width: 11, height: 11)
                    .offset(x: trackW * p - 5.5)
            }
            .frame(width: trackW, height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard player.duration > 0 else { return }
                    player.progress = Double(min(max(v.location.x / trackW, 0), 1))
                })
            HStack {
                Text(formatTime(player.currentTime)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Spacer(minLength: 12)
                Text(formatTime(player.duration)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            .frame(width: trackW)
        }
    }

    // MARK: 歌词

    /// 滚动歌词区。
    ///
    /// 关键实现点：ScrollViewReader + 当前行 id 变化时 `scrollTo(anchor:.center)`。
    /// 不做这件事的话，歌词只会静态躺着，用户得自己滑 —— 那就失去"滚动"的意义。
    /// 用户手动滑动时暂停自动滚动 3 秒，否则刚想往上翻就被拽回去，非常恼人。
    private var lyricsArea: some View {
        LyricsView(player: player)
            .frame(maxWidth: .infinity)
    }

    // MARK: 底部控制

    private var controls: some View {
        VStack(spacing: 18) {
            // 主控制组单独用 ZStack 居中：不与其它兄弟视图共享 HStack，
            // 避免嵌套 Spacer 把子视图挤出位置（实测模式按钮会被挤到进度条那行）。
            ZStack {
                HStack(spacing: 44) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 26))
                    }
                    .frame(width: 50, height: 50)

                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.82, green: 0.28, blue: 0.22))
                                .frame(width: 68, height: 68)
                            if player.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white)
                                    .offset(x: player.isPlaying ? 0 : 2)
                            }
                        }
                        .shadow(color: Color(red: 0.82, green: 0.28, blue: 0.22).opacity(0.35),
                                radius: 14, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 26))
                    }
                    .frame(width: 50, height: 50)
                }
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)

            // 次要操作行：播放模式 + 队列，各自带文字，图标不出现也能看懂。
            HStack(spacing: 56) {
                Button { player.cyclePlayMode() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: player.playMode.icon)
                            .font(.system(size: 17, weight: .medium))
                        Text(player.playMode.title)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(player.playMode == .sequential
                                     ? Color.secondary : Color(red: 0.82, green: 0.28, blue: 0.22))
                    .frame(width: 60)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playMode.title)

                Button { showQueue = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "list.bullet").font(.system(size: 17, weight: .medium))
                        Text("队列").font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                    .frame(width: 60)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放队列")
            }

            if let msg = player.errorMessage {
                Text(msg).font(.system(size: 12)).foregroundColor(.red)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
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
