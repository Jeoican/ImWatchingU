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
    /// 播放请求序号：快速切歌时只认最后一次请求的结果，避免旧请求抢占当前歌
    private var playToken = 0

    private init() {
        configureRemoteCommands()
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
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        audioSessionConfigured = true
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
        if let song = currentSong {
            info[MPMediaItemPropertyTitle] = song.displayName
            info[MPMediaItemPropertyArtist] = song.artists ?? ""
            info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
