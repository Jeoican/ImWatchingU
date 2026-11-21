import Foundation

// MARK: - 错误

/// 网络层错误。刻意区分「鉴权失败」与其它错误：
/// 前者要弹登录，后者只要重试或提示，混在一起会导致 401 时误显示"网络错误"。
enum APIError: LocalizedError, Equatable {
    case unauthorized
    case notConfigured          // 还没填服务器地址或 Token
    case httpStatus(Int)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Token 无效或已吊销，请重新登录"
        case .notConfigured:
            return "尚未配置服务器地址与 Token"
        case .httpStatus(let c):
            return "服务器返回 \(c)"
        case .decoding(let m):
            return "数据解析失败：\(m)"
        case .transport(let m):
            return "网络错误：\(m)"
        }
    }
}

// MARK: - 凭证

/// 服务器地址 + Token 的持久化。
///
/// 为什么不用 Keychain（这是个有意的取舍）
/// --------------------------------------
/// 侧载环境用 TrollStore 伪签名，`application-identifier` 不是真实 Team ID，
/// `keychain-access-groups` 可能异常 —— 典型症状是「能写入，但重装后读不出来」。
/// 所以凭证存文件，配 `.completeFileProtection`：加密由系统密钥链保护，
/// 不依赖 keychain groups，重装也不会丢。
///
/// 存放位置：Documents/credentials.json（受保护的沙盒内，不进备份也可控）。
struct Credentials: Codable, Equatable {
    var baseURL: String
    var token: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 归一化后的基地址。用户可能填 `sw.example.com`、`192.168.1.5:8080`
    /// 或带尾斜杠，这里补 scheme 并去掉末尾 `/`，避免拼出 `https:////api`。
    ///
    /// scheme 的默认选择是有讲究的（踩过坑）：
    /// 曾经一律补 `https://`，结果内网联调时用户填 `192.168.101.163:8080`
    /// 被补成 https，而后端是明文 HTTP 端口，直接 TLS 握手失败、报「发生 SSL 错误」。
    /// 规则改为：
    ///   - 裸 IP / localhost / 127.0.0.1 → http://（内网明文，安全边界由内网承担）
    ///   - 域名 → https://（公网必须 TLS，这是底线）
    /// 用户显式写了 scheme 时一律尊重，不覆盖。
    var normalizedBaseURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://"), !lower.hasPrefix("https://") {
            s = (Self.isIPAddressOrLocal(s) ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// 判断是否是「IP 地址或本地主机名」（可能带端口）。
    /// 用 string 粗判而非 URLComponents：这里只是决定补哪个 scheme，
    /// 真正的合法性交给 URL(string:) 与后续请求去校验。
    private static func isIPAddressOrLocal(_ raw: String) -> Bool {
        // 去掉可能的端口（IPv4 / localhost）
        let host = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        if host.lowercased() == "localhost" { return true }
        // IPv4：四段 0-255 数字
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ p in
            !p.isEmpty && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }) {
            return true
        }
        // IPv6 字面量带方括号
        if host.hasPrefix("["), host.hasSuffix("]") { return true }
        return false
    }
}

final class CredentialStore {
    static let shared = CredentialStore()

    private let queue = DispatchQueue(label: "socialwatch.credentials")
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("credentials.json")
    }

    func load() -> Credentials? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let cred = try? JSONDecoder().decode(Credentials.self, from: data)
            else { return nil }
            return cred
        }
    }

    func save(_ cred: Credentials) throws {
        try queue.sync {
            let data = try JSONEncoder().encode(cred)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}

// MARK: - 客户端

/// 归档接口客户端。
///
/// 与 web 端的分工差异（这是有意设计的）
/// -------------------------------------
/// web 端必须用 Cookie，因为 `<img src>` 是浏览器原生加载、发不出自定义头。
/// Swift 用 URLSession 可以给**所有**请求带 header，实测纯 Bearer 取图返回 200，
/// 所以 App 端只走 Bearer 一种凭证，不需要 Cookie 那一整套逻辑。
///
/// 后端 `_client_token()` 同时接受两者，因此这个简化不会与后端冲突。
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let cfg = URLSessionConfiguration.default
        // 后端是 Python http.server，单进程处理，并发不宜过高
        cfg.httpMaximumConnectionsPerHost = 4
        // 图片走 URLSession 自带缓存（后端已支持 ETag / Range）
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
        decoder = JSONDecoder()
    }

    // MARK: 请求构造

    private func makeRequest(_ path: String,
                             query: [String: String] = [:],
                             method: String = "GET",
                             body: Data? = nil) throws -> URLRequest {
        guard let cred = CredentialStore.shared.load(), cred.isConfigured else {
            throw APIError.notConfigured
        }
        guard let base = cred.normalizedBaseURL else { throw APIError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            ?? URLComponents()
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// 统一请求入口。所有业务接口都走这里，保证鉴权头/状态码/解码行为一致。
    private func request<T: Decodable>(_ path: String,
                                       query: [String: String] = [:],
                                       method: String = "GET",
                                       body: Any? = nil) async throws -> T {
        var bodyData: Data?
        if let body {
            do {
                bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                throw APIError.decoding("请求体序列化失败")
            }
        }
        let req = try makeRequest(path, query: query, method: method, body: bodyData)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport("无 HTTP 响应")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.httpStatus(http.statusCode)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(300).description)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request(path, query: query, method: "GET")
    }

    // MARK: 归档接口

    /// 列表。`cursor` 必须原样透传后端给的 `next_cursor`：
    /// 它是 `posted_at:id` 复合键，拆开重拼会漏掉同一秒内的多条。
    func archiveList(target: String? = nil,
                     platform: String? = nil,
                     state: ContentState? = nil,
                     cursor: String? = nil,
                     limit: Int = 30) async throws -> ArchiveListResponse {
        var q: [String: String] = ["limit": String(limit)]
        if let target, !target.isEmpty { q["target"] = target }
        if let platform, !platform.isEmpty { q["platform"] = platform }
        if let state, state != .unknown { q["state"] = state.rawValue }
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return try await get("/api/archive/list", query: q)
    }

    func archiveItem(id: Int) async throws -> ArchiveDetail {
        let r: ArchiveDetailResponse = try await get("/api/archive/item", query: ["id": String(id)])
        return r.item
    }

    /// 拼图片地址。App 用不到 `/api/archive/media` 之外的任何信息，
    /// 尤其不需要后端返回的 `local_path`（那是容器内路径）。
    func mediaURL(itemID: Int, seq: Int, tier: ThumbTier) throws -> URL {
        guard let cred = CredentialStore.shared.load(), cred.isConfigured else {
            throw APIError.notConfigured
        }
        guard let base = cred.normalizedBaseURL else { throw APIError.notConfigured }
        let mediaPath = base.appendingPathComponent("api/archive/media")
        guard var comps = URLComponents(url: mediaPath, resolvingAgainstBaseURL: false) else {
            throw APIError.notConfigured
        }
        comps.queryItems = [
            URLQueryItem(name: "id", value: String(itemID)),
            URLQueryItem(name: "seq", value: String(seq)),
            URLQueryItem(name: "thumb", value: tier.rawValue),
        ]
        guard let url = comps.url else { throw APIError.notConfigured }
        return url
    }

    /// 带鉴权的图片请求。
    ///
    /// 为什么不直接把 URL 交给 AsyncImage：`<img src>` 等价物发不出 Authorization 头，
    /// AsyncImage 也不支持自定义 header。所以图片必须自己取字节再解码。
    /// 这条链路上后端已备好 ETag / Range，URLSession 会自动处理 304 与断点。
    func mediaRequest(itemID: Int, seq: Int, tier: ThumbTier) throws -> URLRequest {
        guard let cred = CredentialStore.shared.load(), cred.isConfigured else {
            throw APIError.notConfigured
        }
        var req = URLRequest(url: try mediaURL(itemID: itemID, seq: seq, tier: tier))
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: 鉴权

    /// 校验 Token 是否有效（用最小请求探一下）。
    /// 登录页在保存前先验证，避免存进一个无效 Token 然后每次请求都 401。
    func verifyAuth() async throws -> Bool {
        struct Health: Codable { let ok: Bool }
        let _: Health = try await get("/api/auth/status")
        return true
    }

    // MARK: - 看板

    func dashboardState() async throws -> DashboardState {
        try await get("/api/state")
    }

    func events(limit: Int = 200, target: String? = nil, platform: String? = nil) async throws -> [ChangeEvent] {
        var q: [String: String] = ["limit": String(limit)]
        if let target, !target.isEmpty { q["target"] = target }
        if let platform, !platform.isEmpty { q["platform"] = platform }
        let r: EventsResponse = try await get("/api/events", query: q)
        return r.events
    }

    /// 触发巡检。target 为空 = 全局巡检。
    func runCheck(target: String? = nil) async throws -> OKResponse {
        var body: [String: Any] = [:]
        if let target, !target.isEmpty { body["target"] = target }
        return try await request("/api/check", method: "POST", body: body)
    }

    // MARK: - 目标管理

    func addTarget(platform: String, id: String, name: String,
                   people: [String], maxUsers: Int? = nil) async throws -> OKResponse {
        var opts: [String: Any] = ["people": people]
        if let maxUsers { opts["max_users"] = maxUsers }
        let body: [String: Any] = [
            "platform": platform, "id": id, "name": name,
            "enabled": true, "options": opts,
        ]
        return try await request("/api/targets", method: "POST", body: body)
    }

    func updateTarget(index: Int, platform: String, id: String, name: String,
                      enabled: Bool, people: [String], maxUsers: Int? = nil) async throws -> OKResponse {
        var opts: [String: Any] = ["people": people]
        if let maxUsers { opts["max_users"] = maxUsers }
        let body: [String: Any] = [
            "platform": platform, "id": id, "name": name,
            "enabled": enabled, "options": opts,
        ]
        return try await request("/api/targets/\(index)", method: "PUT", body: body)
    }

    func setTargetEnabled(index: Int, enabled: Bool) async throws -> OKResponse {
        try await request("/api/targets/\(index)", method: "PUT", body: ["enabled": enabled])
    }

    func deleteTarget(index: Int) async throws -> OKResponse {
        try await request("/api/targets/\(index)", method: "DELETE")
    }

    func resolveLink(_ url: String) async throws -> ResolveResponse {
        try await request("/api/resolve", method: "POST", body: ["url": url])
    }

    // MARK: - 平台扫码登录（采集凭证）

    func loginFlowStatus(platform: String) async throws -> LoginFlowStatus {
        try await get("/api/login/status", query: ["platform": platform])
    }

    func loginFlowShot(platform: String) async throws -> LoginShotResponse {
        try await get("/api/login/shot", query: ["platform": platform])
    }

    func startLoginFlow(platform: String) async throws -> OKResponse {
        try await request("/api/login/start", method: "POST", body: ["platform": platform])
    }

    func cancelLoginFlow(platform: String) async throws -> OKResponse {
        try await request("/api/login/cancel", method: "POST", body: ["platform": platform])
    }

    // MARK: - 网易云歌单 / 播放

    func musicPlaylists() async throws -> [MusicPlaylist] {
        let r: MusicPlaylistsResponse = try await get("/api/music/playlists")
        return r.playlists
    }

    func musicSongs(playlist: String, target: String? = nil) async throws -> [MusicSong] {
        var q = ["playlist": playlist]
        if let target, !target.isEmpty { q["target"] = target }
        let r: MusicSongsResponse = try await get("/api/music/songs", query: q)
        return r.songs
    }

    /// 批量换临时播放地址。地址带时效签名，应立即交给播放器，不要缓存。
    func musicPlayURLs(ids: [String]) async throws -> [String: PlayURL] {
        guard !ids.isEmpty else { return [:] }
        let r: MusicURLsResponse = try await get("/api/music/url",
                                                 query: ["ids": ids.joined(separator: ",")])
        return r.urls
    }

    // MARK: - 图片代理（任意远程 URL，如头像/封面）

    /// `/api/img?url=` 的带鉴权请求。头像/歌单封面走它；
    /// 归档内容里的图继续用 mediaRequest（带 id/seq/thumb）。
    func remoteImageRequest(url: String) throws -> URLRequest {
        guard let cred = CredentialStore.shared.load(), cred.isConfigured else {
            throw APIError.notConfigured
        }
        guard let base = cred.normalizedBaseURL else { throw APIError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent("api/img"), resolvingAgainstBaseURL: false)
            ?? URLComponents()
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        guard let finalURL = comps.url else { throw APIError.notConfigured }
        var req = URLRequest(url: finalURL)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        return req
    }
}
