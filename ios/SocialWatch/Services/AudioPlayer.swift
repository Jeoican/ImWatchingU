import AVFoundation
import MediaPlayer
import SwiftUI

/// 全局音频播放器。
///
/// 为什么是单例而不是塞在某个 View 的 @StateObject：
/// 播放器要跨「歌曲列表页 ↔ 迷你播放条 ↔ 全屏播放页」存活，切 Tab、返回列表
/// 都不能中断播放。单例 + ObservableObject 让所有界面共享同一份播放状态。
///
/// 播放地址的生命周期：网易云给的是带时效签名的临时 URL，这里**不缓存**，
/// 每次真正要播某首歌时才向后端换取，拿到立刻交给 AVPlayer。
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    // MARK: 对外状态
    @Published var queue: [MusicSong] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?
    /// 当前所在歌单名，迷你条与全屏页标题用
    @Published var playlistTitle: String = ""

    // MARK: 歌词

    @Published var lyrics: [LyricLine] = []
    @Published var lyricLoading = false
    /// 后端明确确认过「这首歌本来就没有歌词」（纯音乐等），
    /// 与「还没加载完」区分开，避免歌词区长时间转圈。
    @Published var lyricAbsent = false

    /// 当前唱到第几行。播放器每次更新进度时算一次，
    /// 用二分定位而不是遍历：几百行歌词 × 每 0.5 秒一次，遍历会白白耗电。
    @Published var currentLyricIndex: Int = -1

    private var lyricCache: [String: [LyricLine]] = [:]
    /// 播放请求序号：快速切歌时只认最后一次请求的结果，避免旧请求抢占当前歌
    private var playToken = 0

    var currentSong: MusicSong? {
        guard currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var progress: Double {
        get { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }
        set { seek(to: newValue * duration) }
    }

    // MARK: 内部
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioSessionConfigured = false

    /// 已备好的锁屏/灵动岛封面，按 song_id 缓存。
    /// 封面同一首歌不会变，重下一遍纯属浪费；而且「正在播放」信息会被
    /// 反复重设（暂停、拖动进度、切后台），每次都走网络会明显卡顿。
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    /// 封面请求序号：切歌后旧的封面回来不能覆盖新歌的封面
    private var artworkToken = 0

    private init() {
        configureRemoteCommands()
        observeInterruptions()
    }

    // MARK: - 播放控制

    func play(queue: [MusicSong], at index: Int, playlistTitle: String = "") {
        self.queue = queue
        self.playlistTitle = playlistTitle
        play(at: index)
    }

    func play(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        playToken += 1
        let token = playToken
        currentIndex = index
        errorMessage = nil
        currentTime = 0
        duration = 0
        isLoading = true
        // 歌词与播放地址并行拉，两边互不等待：
        // 歌词慢不该拖住出声，出声了歌词再补上也完全可接受。
        loadLyrics(for: queue[index], token: token)

        let song = queue[index]
        Task {
            do {
                let urls = try await APIClient.shared.musicPlayURLs(ids: [song.id])
                guard token == self.playToken else { return }  // 已被后续切歌取代
                self.isLoading = false
                guard let playURL = urls[song.id], let str = playURL.url, let url = URL(string: str) else {
                    self.errorMessage = "「\(song.displayName)」暂时无法播放（可能需会员或已下架）"
                    self.isPlaying = false
                    return
                }
                self.start(url: url)
            } catch {
                guard token == self.playToken else { return }
                self.isLoading = false
                self.errorMessage = "获取播放地址失败：\(error.localizedDescription)"
                self.isPlaying = false
            }
        }
    }

    // MARK: - 歌词

    private func loadLyrics(for song: MusicSong, token: Int) {
        // 切歌先清空，避免新歌开播前还挂着上一首的歌词（视觉上非常出戏）
        lyrics = []
        currentLyricIndex = -1
        lyricAbsent = false

        if let hit = lyricCache[song.id] {
            lyrics = hit
            lyricAbsent = hit.isEmpty
            return
        }
        lyricLoading = true
        Task {
            // 歌词按 song_id 几乎不变，先用磁盘缓存兜住 —— 弱网也能看到词
            if let cached = DataCache.load("music:lyric:\(song.id)", as: [LyricLine].self,
                                           maxAge: 90 * 24 * 3600) {
                self.lyricCache[song.id] = cached
                guard token == self.playToken else { return }
                self.lyrics = cached
                self.lyricAbsent = cached.isEmpty
                self.lyricLoading = false
                return
            }
            do {
                let (lines, none) = try await APIClient.shared.musicLyric(id: song.id)
                guard token == self.playToken else { return }
                self.lyricCache[song.id] = lines
                self.lyrics = lines
                self.lyricAbsent = none || lines.isEmpty
                self.lyricLoading = false
                if !lines.isEmpty {
                    DataCache.save("music:lyric:\(song.id)", value: lines)
                }
            } catch {
                guard token == self.playToken else { return }
                self.lyricLoading = false
                self.lyricAbsent = true
            }
        }
    }

    /// 二分找「最后一个 t <= 当前时间」的行号。返回 -1 表示还没唱到第一句。
    ///
    /// 为什么不用 `lyrics.lastIndex(where:)`：那是 O(n) 全扫，
    /// 而这个方法每 0.5 秒被调一次、歌词常有 60–100 行，
    /// 二分是 O(log n)，代价可以忽略。且歌词已按时间升序，前提成立。
    private func lyricIndex(at time: Double) -> Int {
        guard !lyrics.isEmpty else { return -1 }
        if time < lyrics[0].t { return -1 }
        var lo = 0, hi = lyrics.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lyrics[mid].t <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func start(url: URL) {
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        configureAudioSession()

        // 进度观察（每 0.5 秒回主线程更新，足够流畅且不掉帧）
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let t = time.seconds
            let d = p.currentItem?.duration.seconds ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = t.isFinite ? t : 0
                if d.isFinite && d > 0 { self.duration = d }
                let idx = self.lyricIndex(at: self.currentTime)
                // 只在换行时写 @Published，避免每 0.5 秒都触发全视图重绘
                if idx != self.currentLyricIndex { self.currentLyricIndex = idx }
            }
        }

        // 播放结束自动下一首
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
        }

        p.play()
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() {
        guard let player else {
            if currentIndex >= 0 { play(at: currentIndex) }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func next() {
        guard currentIndex + 1 < queue.count else {
            player?.pause(); isPlaying = false
            return
        }
        play(at: currentIndex + 1)
    }

    func previous() {
        // 播过 3 秒以上时，「上一首」先回到本曲开头（播放器通用习惯）
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard currentIndex - 1 >= 0 else {
            seek(to: 0)
            return
        }
        play(at: currentIndex - 1)
    }

    func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        let t = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        currentTime = t
    }

    func stop() {
        teardownPlayer()
        queue = []
        currentIndex = -1
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func teardownPlayer() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }

    // MARK: - 系统音频 / 锁屏控制

    private func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        // .playback：静音键拨下也照样出声，这是音乐 App 的基本预期。
        // 配合 Info.plist 的 UIBackgroundModes=audio，切到后台才不会被挂起。
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        audioSessionConfigured = true
    }

    /// 来电、闹钟、其它 App 抢音频时系统会中断我们的会话。
    /// 不处理的话表现为「放着放着没声了，点播放也没反应」——
    /// 因为会话已失效，必须重新 setActive 才能继续。
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    // 被系统打断（来电等）：播放器已经停了，状态要跟上，
                    // 否则界面还显示「暂停键」但没声音。
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)
                    self.reactivateSession()
                    if shouldResume, self.player != nil {
                        self.player?.play()
                        self.isPlaying = true
                    }
                    self.updateNowPlaying()
                @unknown default:
                    break
                }
            }
        }
    }

    /// 重新激活音频会话。被中断后会话处于 inactive，
    /// 直接 play() 是无效的，必须先 setActive(true)。
    private func reactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == false { self?.togglePlayPause() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true { self?.togglePlayPause() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        var missingArtwork = false
        if let song = currentSong {
            info[MPMediaItemPropertyTitle] = song.displayName
            info[MPMediaItemPropertyArtist] = song.artists ?? ""
            info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
            if let art = artworkCache[song.id] {
                info[MPMediaItemPropertyArtwork] = art
            } else {
                missingArtwork = true
            }
        }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        // PlaybackRate 决定锁屏卡的进度条自己走还是停住。
        // 只给 1.0/0.0 是不够的：系统据此推算当前进度，
        // 若和实际 elapsedTime 不匹配，卡片进度会跳。
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if missingArtwork { loadArtwork() }
    }

    /// 把专辑封面喂给「正在播放」。
    ///
    /// 为什么之前灵动岛/锁屏没有封面：`MPNowPlayingInfoCenter` 只认
    /// `MPMediaItemPropertyArtwork` 这个键，给一个 URL 字符串它不理。
    /// 系统不会自己去下载封面 —— 必须 App 自己取到 UIImage 再包成
    /// MPMediaItemArtwork。这里和界面走同一条 `/api/img` 代理（带 Bearer），
    /// 所以直接复用 ImageLoader 的缓存：界面刚显示过封面，这里立刻命中。
    private func loadArtwork() {
        guard let song = currentSong, let cover = song.cover, !cover.isEmpty else { return }
        artworkToken += 1
        let token = artworkToken
        let songID = song.id

        // 内存命中（界面已加载过这张封面）→ 零延迟直接设上
        if let cached = ImageLoader.sharedCachedImage(for: cover) {
            applyArtwork(cached, songID: songID, token: token)
            return
        }

        let loader = ImageLoader()
        loader.onImage = { [weak self] img in
            Task { @MainActor in
                self?.applyArtwork(img, songID: songID, token: token)
            }
        }
        loader.load(remoteURL: cover)
    }

    private func applyArtwork(_ img: UIImage, songID: String, token: Int) {
        // 切歌了：这张封面已作废，别把上一首的图贴到新歌上
        guard token == artworkToken, currentSong?.id == songID else { return }
        guard artworkCache[songID] == nil else { return }
        let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        artworkCache[songID] = art
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } else {
            updateNowPlaying()
        }
    }
}
