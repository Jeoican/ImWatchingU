import Foundation
import os

/// 启动自检（仅 DEBUG）。
///
/// 为什么需要它
/// ------------
/// 后端是 Python `http.server`，不输出 access log，因此「App 到底有没有
/// 取到数据」在容器侧完全看不见。没有日志就只能凭截图猜，而截图会骗人
/// （锁屏、加载中、错误页长得都像正常页）。所以在这里主动打一枪，
/// 把状态码、条目数、图片字节数写进系统日志，`log show` 就能取到铁证。
///
/// Release 构建下整个文件不参与编译，不会残留任何调试代码。
#if DEBUG
enum StartupProbe {
    private static let log = Logger(subsystem: "com.jeoi.socialwatch", category: "probe")

    static func run() {
        Task {
            guard let cred = CredentialStore.shared.load(), cred.isConfigured else {
                log.notice("PROBE skip reason=no-credentials")
                return
            }
            log.notice("PROBE base=\(cred.baseURL, privacy: .public) tokenLen=\(cred.token.count)")

            do {
                // 1) 列表：验证 鉴权 + JSON 解码
                let list = try await APIClient.shared.archiveList(limit: 5)
                let grand = list.stats.values.reduce(0) { $0 + $1.total }
                let mediaCount = list.stats.values.reduce(0) { $0 + $1.media }
                log.notice("PROBE list ok items=\(list.items.count) targets=\(list.stats.count) total=\(grand) media=\(mediaCount) hasMore=\(list.hasMore)")

                guard let first = list.items.first else {
                    log.notice("PROBE list-empty")
                    return
                }
                log.notice("PROBE first id=\(first.id) media=\(first.mediaTotal) state=\(first.state.rawValue)")

                // 2) 详情：验证 detail 契约
                let detail = try await APIClient.shared.archiveItem(id: first.id)
                log.notice("PROBE detail ok id=\(detail.id) media=\(detail.media.count) textLen=\(detail.text.count)")

                // 3) 图片：验证 Bearer 取图 + 三档缩略图
                //    这是整个 App 最关键的一条链路 —— 网页端靠 Cookie，
                //    App 端靠自定义 header，两者都必须落 200。
                if let m = detail.media.first(where: { $0.cached == true }) ?? detail.media.first {
                    for tier in [ThumbTier.list, .detail, .original] {
                        let req = try APIClient.shared.mediaRequest(itemID: detail.id, seq: m.seq, tier: tier)
                        let (data, resp) = try await URLSession.shared.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        let mime = resp.mimeType ?? "-"
                        log.notice("PROBE media thumb=\(tier.rawValue) code=\(code) bytes=\(data.count) mime=\(mime, privacy: .public)")
                    }
                } else {
                    log.notice("PROBE media-none itemId=\(detail.id)")
                }

                log.notice("PROBE done ALL-GREEN")
            } catch {
                log.error("PROBE FAIL \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
