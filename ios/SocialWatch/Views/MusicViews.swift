import SwiftUI
import Combine

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
                .fullScreenCover(isPresented: $showFullPlayer) {
                    FullPlayerUIKit()
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
                .fullScreenCover(isPresented: $showFullPlayer) { FullPlayerUIKit() }
            }
        }
    }
}

// MARK: - 全屏播放器（UIKit 重写）
//
// 为什么放弃 SwiftUI 版：iOS 16 真机上 SwiftUI 的 .sheet 会把**整个内容视图**连同所有
// 子视图统一右移约 17pt（真机像素实测：封面、歌名、播放键、进度条、header 全部同量偏移，
// 而 iOS 27 模拟器完全居中）。这是呈现容器层面的坐标偏移，改任何内部 frame / alignment
// 都无效 —— 上一轮加 frame(width:screenW) 仍偏移，就是这个原因。
//
// UIKit 方案：UIViewController.view.bounds 原点恒为 (0,0)、宽度恒为屏幕宽度，
// 所有子视图用**绝对 frame**按 bounds.midX 定位，不受 sheet 呈现机制的坐标偏移影响。
// 用 .fullScreenCover 呈现：换一套呈现机制绕开该 bug，同时消除 sheet 顶部的卡片漏边。

/// SwiftUI → UIKit 桥接。接口保持简单，底层全用 AudioPlayer.shared。
struct FullPlayerUIKit: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FullPlayerViewController {
        FullPlayerViewController()
    }
    func updateUIViewController(_ uiViewController: FullPlayerViewController, context: Context) {}
}

@MainActor
final class FullPlayerViewController: UIViewController {
    private let player = AudioPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var showingLyrics = false
    private var coverURL: String?
    private var imageLoaders: [ImageLoader] = []
    private var lastLyricIndex = -2

    private let accent = UIColor(red: 0.82, green: 0.28, blue: 0.22, alpha: 1)
    private let muted = UIColor.label.withAlphaComponent(0.72)

    // 背景层
    private let bgImageView = UIImageView()
    private let bgBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let bgTintView = UIView()
    private let bgGradient = CAGradientLayer()
    private let shadeGradient = CAGradientLayer()

    // 顶部栏
    private let headerView = UIView()
    private let closeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let titleLabel = UILabel()
    private let headerQueueButton = UIButton(type: .system)

    // 封面页
    private let coverPage = UIView()
    private let coverShadowView = UIView()
    private let coverImageView = UIImageView()
    private let songLabel = UILabel()
    private let artistLabel = UILabel()
    private let previewLabel = UILabel()

    // 歌词页
    private let lyricsPage = UIView()
    private let collapseButton = UIButton(type: .system)
    private let lyricsScrollView = UIScrollView()
    private let lyricsStack = UIStackView()
    private var lyricLabels: [UILabel] = []
    private var lyricSongID: String?

    // 控制区
    private let deckView = UIView()
    private let seekBar = UIView()
    private let seekTrack = UIView()
    private let seekFill = UIView()
    private let seekThumb = UIView()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let prevButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .custom)
    private let modeIcon = UIImageView()
    private let modeLabel = UILabel()
    private let deckQueueButton = UIButton(type: .custom)
    private let queueIcon = UIImageView()
    private let queueLabel = UILabel()
    private let errorLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        modalPresentationCapturesStatusBarAppearance = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["SW_DEBUG_LYRICS"] == "1" { showingLyrics = true }
        #endif
        buildUI()
        bind()
        refreshAll()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layout()
    }

    // MARK: 构建视图层级

    private func buildUI() {
        // 背景：封面 → 高斯模糊 → 主题色渐变 → 可读性遮罩
        bgImageView.contentMode = .scaleAspectFill
        bgImageView.clipsToBounds = true
        view.addSubview(bgImageView)
        view.addSubview(bgBlurView)
        // 暗色遮罩：压住封面取色的亮度，避免橙色瞳孔放大成刺眼光斑
        bgTintView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        view.addSubview(bgTintView)
        bgGradient.colors = [accent.withAlphaComponent(0.20).cgColor,
                             UIColor.clear.cgColor,
                             accent.withAlphaComponent(0.16).cgColor]
        bgGradient.locations = [0, 0.5, 1]
        view.layer.insertSublayer(bgGradient, at: 0)
        shadeGradient.colors = [UIColor.black.withAlphaComponent(0.06).cgColor,
                                UIColor.black.withAlphaComponent(0.34).cgColor]
        shadeGradient.locations = [0, 1]
        view.layer.insertSublayer(shadeGradient, above: bgGradient)

        // 顶部栏
        setupCloseButton(closeButton)
        closeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        headerView.addSubview(closeButton)

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = muted
        statusLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        headerView.addSubview(statusLabel)
        headerView.addSubview(titleLabel)

        setupCloseButton(headerQueueButton)
        headerQueueButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        headerQueueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
        headerView.addSubview(headerQueueButton)
        view.addSubview(headerView)

        // 封面页
        coverPage.addSubview(coverShadowView)
        coverShadowView.layer.shadowColor = UIColor.black.cgColor
        coverShadowView.layer.shadowOpacity = 0.3
        coverShadowView.layer.shadowRadius = 20
        coverShadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
        coverShadowView.addSubview(coverImageView)
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.layer.cornerRadius = 16
        coverImageView.isUserInteractionEnabled = true
        coverImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(coverTapped)))
        coverPage.addSubview(songLabel)
        songLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        songLabel.textAlignment = .center
        coverPage.addSubview(artistLabel)
        artistLabel.font = .systemFont(ofSize: 13, weight: .medium)
        artistLabel.textColor = muted
        artistLabel.textAlignment = .center
        coverPage.addSubview(previewLabel)
        previewLabel.font = .systemFont(ofSize: 12, weight: .medium)
        previewLabel.textColor = muted
        previewLabel.textAlignment = .center
        previewLabel.numberOfLines = 1
        view.addSubview(coverPage)

        // 歌词页
        collapseButton.setTitle("收起歌词", for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        collapseButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        collapseButton.tintColor = muted
        collapseButton.setTitleColor(muted, for: .normal)
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        lyricsPage.addSubview(collapseButton)
        lyricsScrollView.showsVerticalScrollIndicator = false
        lyricsStack.axis = .vertical
        lyricsStack.alignment = .fill
        lyricsStack.spacing = 20
        lyricsScrollView.addSubview(lyricsStack)
        lyricsPage.addSubview(lyricsScrollView)
        view.addSubview(lyricsPage)

        // 控制区：自绘进度条
        seekTrack.backgroundColor = UIColor.label.withAlphaComponent(0.28)
        seekTrack.layer.cornerRadius = 2.5
        seekFill.backgroundColor = accent
        seekFill.layer.cornerRadius = 2.5
        seekThumb.backgroundColor = accent
        seekThumb.layer.cornerRadius = 6.5
        seekBar.addSubview(seekTrack)
        seekBar.addSubview(seekFill)
        seekBar.addSubview(seekThumb)
        seekBar.isUserInteractionEnabled = true
        seekBar.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(seekPanned(_:))))
        currentTimeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        currentTimeLabel.textColor = muted
        durationLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = muted
        durationLabel.textAlignment = .right
        seekBar.addSubview(currentTimeLabel)
        seekBar.addSubview(durationLabel)
        deckView.addSubview(seekBar)

        // 主控制
        prevButton.setImage(UIImage(systemName: "backward"), for: .normal)
        prevButton.tintColor = .label
        prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.backgroundColor = accent
        playButton.layer.cornerRadius = 33
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "forward"), for: .normal)
        nextButton.tintColor = .label
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        [prevButton, playButton, nextButton].forEach { deckView.addSubview($0) }

        // 模式 / 队列：用 custom Button + 独立 imageView/label，图在上字在下，
        // 避开 UIButton.Configuration 在窄宽度下把中文标题挤成竖排的问题。
        setupDeckAction(modeButton, icon: modeIcon, label: modeLabel,
                        symbol: "arrow.right", text: "顺序播放")
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        setupDeckAction(deckQueueButton, icon: queueIcon, label: queueLabel,
                        symbol: "list.bullet", text: "队列")
        deckQueueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        deckView.addSubview(errorLabel)
        view.addSubview(deckView)

        updatePageVisibility()
    }

    private func setupCloseButton(_ b: UIButton) {
        b.tintColor = .label
        b.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        b.layer.cornerRadius = 20
    }

    private func setupDeckAction(_ b: UIButton, icon: UIImageView, label: UILabel,
                                 symbol: String, text: String) {
        icon.image = UIImage(systemName: symbol)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = muted
        label.text = text
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = muted
        label.textAlignment = .center
        b.addSubview(icon)
        b.addSubview(label)
        deckView.addSubview(b)
    }

    // MARK: 布局（全部绝对 frame，基于 bounds 中心 —— 不受呈现容器偏移影响）

    private func layout() {
        let W = view.bounds.width
        let H = view.bounds.height
        let safeTop = view.safeAreaInsets.top
        let safeBottom = view.safeAreaInsets.bottom

        bgImageView.frame = view.bounds
        bgBlurView.frame = view.bounds
        bgTintView.frame = view.bounds
        bgGradient.frame = view.bounds
        shadeGradient.frame = view.bounds

        // 顶部栏：三栏绝对居中
        let headerH: CGFloat = 48
        headerView.frame = CGRect(x: 0, y: safeTop, width: W, height: headerH)
        closeButton.frame = CGRect(x: 16, y: 4, width: 40, height: 40)
        headerQueueButton.frame = CGRect(x: W - 56, y: 4, width: 40, height: 40)
        let titleW = W - 128
        statusLabel.frame = CGRect(x: (W - titleW) / 2, y: 5, width: titleW, height: 15)
        titleLabel.frame = CGRect(x: (W - titleW) / 2, y: 21, width: titleW, height: 20)

        let deckH: CGFloat = 214
        let deckY = H - safeBottom - deckH
        let pageTop = safeTop + headerH
        let pageH = max(160, deckY - pageTop - 6)

        // 封面页
        coverPage.frame = CGRect(x: 0, y: pageTop, width: W, height: pageH)
        let side = min(258, W - 120)
        coverShadowView.frame = CGRect(x: (W - side) / 2, y: 20, width: side, height: side)
        coverImageView.frame = coverShadowView.bounds
        songLabel.frame = CGRect(x: 24, y: 20 + side + 18, width: W - 48, height: 28)
        artistLabel.frame = CGRect(x: 24, y: songLabel.frame.maxY + 2, width: W - 48, height: 20)
        previewLabel.frame = CGRect(x: 24, y: artistLabel.frame.maxY + 12, width: W - 48, height: 20)

        // 歌词页
        lyricsPage.frame = coverPage.frame
        collapseButton.frame = CGRect(x: W / 2 - 70, y: 4, width: 140, height: 30)
        lyricsScrollView.frame = CGRect(x: 20, y: 38, width: W - 40, height: pageH - 46)
        layoutLyricsStack()

        // 控制区
        deckView.frame = CGRect(x: 0, y: deckY, width: W, height: deckH)
        let trackW = W - 48
        seekBar.frame = CGRect(x: 24, y: 8, width: trackW, height: 42)
        seekTrack.frame = CGRect(x: 0, y: 6, width: trackW, height: 5)
        currentTimeLabel.frame = CGRect(x: 0, y: 20, width: 70, height: 16)
        durationLabel.frame = CGRect(x: trackW - 70, y: 20, width: 70, height: 16)
        updateProgress()

        let cy: CGFloat = 78
        playButton.frame = CGRect(x: W / 2 - 33, y: cy, width: 66, height: 66)
        prevButton.frame = CGRect(x: W / 2 - 33 - 24 - 50, y: cy + 8, width: 50, height: 50)
        nextButton.frame = CGRect(x: W / 2 + 33 + 24, y: cy + 8, width: 50, height: 50)

        let actionW: CGFloat = 76
        modeButton.frame = CGRect(x: W / 2 - 116, y: 150, width: actionW, height: 50)
        deckQueueButton.frame = CGRect(x: W / 2 + 40, y: 150, width: actionW, height: 50)
        for (btn, icon, label) in [(modeButton, modeIcon, modeLabel),
                                   (deckQueueButton, queueIcon, queueLabel)] {
            icon.frame = CGRect(x: (actionW - 22) / 2, y: 2, width: 22, height: 22)
            label.frame = CGRect(x: 0, y: 27, width: actionW, height: 16)
            _ = btn
        }
        errorLabel.frame = CGRect(x: 24, y: 194, width: W - 48, height: 18)
    }

    private func layoutLyricsStack() {
        let w = lyricsScrollView.bounds.width
        guard w > 0 else { return }
        let size = lyricsStack.systemLayoutSizeFitting(
            CGSize(width: w, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        lyricsStack.frame = CGRect(x: 0, y: 80, width: w, height: size.height)
        lyricsScrollView.contentSize = CGSize(width: w, height: lyricsStack.frame.maxY + 40)
    }

    // MARK: 订阅 AudioPlayer

    private func bind() {
        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAll() }
            }
            .store(in: &cancellables)
    }

    private func refreshAll() {
        let song = player.currentSong
        statusLabel.text = player.isLoading ? "加载中…" : (player.isPlaying ? "正在播放" : "已暂停")
        titleLabel.text = player.playlistTitle.isEmpty ? "正在播放" : player.playlistTitle
        songLabel.text = song?.displayName ?? "未在播放"
        artistLabel.text = song?.artists ?? "未知歌手"
        previewLabel.text = currentLyricText()

        let imgName = player.isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: imgName), for: .normal)

        let mode = player.playMode
        let modeColor = mode == .sequential ? muted : accent
        modeIcon.image = UIImage(systemName: mode.icon)
        modeIcon.tintColor = modeColor
        modeLabel.text = mode.title
        modeLabel.textColor = modeColor

        errorLabel.text = player.errorMessage
        errorLabel.isHidden = player.errorMessage == nil

        loadCover(song?.cover)
        rebuildLyricsIfNeeded()
        updateLyricsHighlight()
        updateProgress()
    }

    private func currentLyricText() -> String {
        let i = player.currentLyricIndex
        guard i >= 0, i < player.lyrics.count else { return "" }
        return player.lyrics[i].text
    }

    private func updateProgress() {
        let w = seekBar.bounds.width
        guard w > 0 else { return }
        let p = CGFloat(min(max(player.progress, 0), 1))
        seekFill.frame = CGRect(x: 0, y: seekTrack.frame.minY, width: w * p, height: seekTrack.bounds.height)
        seekThumb.frame = CGRect(x: w * p - 6.5, y: seekTrack.frame.minY - 5.5, width: 13, height: 13)
        currentTimeLabel.text = fmtTime(player.currentTime)
        durationLabel.text = fmtTime(player.duration)
    }

    private func fmtTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 封面

    private func loadCover(_ url: String?) {
        guard let url, !url.isEmpty else {
            coverImageView.image = nil
            bgImageView.image = nil
            bgBlurView.isHidden = false
            return
        }
        if coverURL == url { return }
        coverURL = url
        if let cached = ImageLoader.sharedCachedImage(for: url) {
            applyCover(cached)
            return
        }
        bgBlurView.isHidden = false
        let loader = ImageLoader()
        loader.onImage = { [weak self] img in
            Task { @MainActor [weak self] in self?.applyCover(img) }
        }
        imageLoaders.append(loader)
        loader.load(remoteURL: url)
        // 只保留最近几个 loader，防止无限增长
        if imageLoaders.count > 4 { imageLoaders.removeFirst() }
    }

    private func applyCover(_ img: UIImage) {
        coverImageView.image = img
        // 背景：放大 + 提饱和 + 高斯模糊，一次成像（比 UIVisualEffectView 取色更浓）
        if let bg = makeBackground(from: img) {
            bgImageView.image = bg
            bgBlurView.isHidden = true
        } else {
            bgImageView.image = img
        }
    }

    private func makeBackground(from image: UIImage) -> UIImage? {
        guard let ci = CIImage(image: image) else { return nil }
        // 缩小放大倍数、降低饱和度、加大模糊半径：暖调氛围而不刺眼
        let scale: CGFloat = 1.2
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sat = CIFilter(name: "CIColorControls")
        sat?.setValue(scaled, forKey: kCIInputImageKey)
        sat?.setValue(1.15, forKey: kCIInputSaturationKey)
        sat?.setValue(0.92, forKey: kCIInputBrightnessKey)
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(sat?.outputImage ?? scaled, forKey: kCIInputImageKey)
        blur?.setValue(40, forKey: kCIInputRadiusKey)
        guard let out = blur?.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: 歌词

    private func rebuildLyricsIfNeeded() {
        let sid = player.currentSong?.id ?? ""
        guard lyricSongID != sid || lyricLabels.count != player.lyrics.count else { return }
        lyricSongID = sid
        lyricLabels.removeAll()
        lyricsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, line) in player.lyrics.enumerated() {
            let lb = UILabel()
            lb.text = line.text
            lb.font = .systemFont(ofSize: 17, weight: .medium)
            lb.textColor = muted
            lb.textAlignment = .center
            lb.numberOfLines = 0
            lb.tag = i
            lb.isUserInteractionEnabled = true
            lb.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(lyricTapped(_:))))
            lyricsStack.addArrangedSubview(lb)
            lyricLabels.append(lb)
        }
        layoutLyricsStack()
        lastLyricIndex = -2
    }

    private func updateLyricsHighlight() {
        let idx = player.currentLyricIndex
        for (i, lb) in lyricLabels.enumerated() {
            let active = i == idx
            lb.textColor = active ? accent : muted
            lb.font = .systemFont(ofSize: active ? 19 : 17, weight: active ? .semibold : .medium)
        }
        guard idx >= 0, idx < lyricLabels.count, idx != lastLyricIndex else { return }
        lastLyricIndex = idx
        let lb = lyricLabels[idx]
        let targetY = lyricsStack.frame.origin.y + lb.frame.minY - lyricsScrollView.bounds.height / 2 + lb.frame.height / 2
        let maxY = max(0, lyricsScrollView.contentSize.height - lyricsScrollView.bounds.height)
        lyricsScrollView.setContentOffset(CGPoint(x: 0, y: min(max(targetY, 0), maxY)), animated: true)
    }

    private func updatePageVisibility() {
        coverPage.isHidden = showingLyrics
        lyricsPage.isHidden = !showingLyrics
    }

    // MARK: 交互

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func coverTapped() {
        switchPage(to: true)
    }

    @objc private func collapseTapped() {
        switchPage(to: false)
    }

    private func switchPage(to lyrics: Bool) {
        let from = lyrics ? coverPage : lyricsPage
        let to = lyrics ? lyricsPage : coverPage
        UIView.transition(from: from, to: to, duration: 0.22,
                          options: [.transitionCrossDissolve, .showHideTransitionViews],
                          completion: nil)
        showingLyrics = lyrics
        updatePageVisibility()
    }

    @objc private func playTapped() { player.togglePlayPause() }
    @objc private func prevTapped() { player.previous() }
    @objc private func nextTapped() { player.next() }
    @objc private func modeTapped() { player.cyclePlayMode() }

    @objc private func queueTapped() {
        let host = UIHostingController(rootView: PlayQueueSheet().environmentObject(player))
        host.modalPresentationStyle = .pageSheet
        present(host, animated: true)
    }

    @objc private func seekPanned(_ g: UIPanGestureRecognizer) {
        let w = seekBar.bounds.width
        guard w > 0, player.duration > 0 else { return }
        let x = g.location(in: seekBar).x
        player.progress = Double(min(max(x / w, 0), 1))
    }

    @objc private func lyricTapped(_ g: UITapGestureRecognizer) {
        guard let lb = g.view as? UILabel else { return }
        let i = lb.tag
        guard i >= 0, i < player.lyrics.count else { return }
        player.seek(to: player.lyrics[i].t)
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
