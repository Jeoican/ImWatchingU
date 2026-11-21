import Foundation
import CommonCrypto

/// 业务数据磁盘缓存。
///
/// 为什么需要：
///   后端所有接口都发 `Cache-Control: no-store`，加上请求带 Bearer Token，
///   URLSession 不会缓存业务 JSON——每次进详情、切 Tab 都实打实回源。
///   这个缓存让页面「先显示上次的数据，再后台静默刷新」，断网/弱网也能看内容。
///
/// 设计：
///   - 存 Documents/Cache/，每个 key 一个 JSON 文件；文件名是 key 的 SHA1，
///     避免平台 key（含冒号）当文件名出问题和路径注入。
///   - 文件里是 `{savedAt, data}`：data 是接口原始 JSON 的 Data，
///     这样读写不依赖具体模型类型，任何 Codable 都能缓存。
///   - maxAge 过期只影响「是否当作有效缓存」；过期文件不删（下次还能当
///     stale 兜底展示），由调用方决定是否用。
///   - 读写串行队列保护，避免看板轮询与详情页同时读写同一文件。
enum DataCache {
    private static let dir: URL? = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let d = base?.appendingPathComponent("Cache", isDirectory: true)
        if let d, !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }()

    private static let queue = DispatchQueue(label: "com.jeoi.socialwatch.datacache", qos: .utility)

    private struct Entry: Codable {
        let savedAt: TimeInterval
        let data: Data
    }

    /// 读缓存。maxAge 秒内有效；超时返回 nil（但文件保留，可佐证 stale）。
    static func load<T: Decodable>(_ key: String, as type: T.Type = T.self,
                                   maxAge: TimeInterval) -> T? {
        guard let url = fileURL(key) else { return nil }
        return queue.sync {
            guard let raw = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: raw),
                  Date().timeIntervalSince1970 - entry.savedAt <= maxAge,
                  let value = try? JSONDecoder().decode(T.self, from: entry.data)
            else { return nil }
            return value
        }
    }

    /// 写缓存。value 先编码成 Data 再包一层时间戳落盘（原子写，防中断损坏）。
    static func save<T: Encodable>(_ key: String, value: T) {
        guard let url = fileURL(key),
              let data = try? JSONEncoder().encode(value) else { return }
        let entry = Entry(savedAt: Date().timeIntervalSince1970, data: data)
        guard let raw = try? JSONEncoder().encode(entry) else { return }
        queue.sync {
            try? raw.write(to: url, options: .atomic)
        }
    }

    /// 缓存文件是否新鲜（用于决定是否跳过刷新；目前各页仍会刷新，保留给将来用）。
    static func isFresh(_ key: String, maxAge: TimeInterval) -> Bool {
        guard let url = fileURL(key) else { return false }
        return queue.sync {
            guard let raw = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: raw)
            else { return false }
            return Date().timeIntervalSince1970 - entry.savedAt <= maxAge
        }
    }

    /// 清空全部缓存（设置页「清除缓存」用）。
    static func clearAll() {
        guard let dir else { return }
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for f in files {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
    }

    private static func fileURL(_ key: String) -> URL? {
        guard let dir else { return nil }
        let name = sha1(key) + ".json"
        return dir.appendingPathComponent(name)
    }

    private static func sha1(_ s: String) -> String {
        var digest = [UInt8](repeating: 0, count: 20)
        let data = Data(s.utf8)
        data.withUnsafeBytes { buf in
            _ = CC_SHA1(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
