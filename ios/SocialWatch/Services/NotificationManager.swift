import Foundation
import UserNotifications
import UIKit

/// 原生本地通知中枢。
///
/// 为什么是「本地通知」而不是走服务器推送：
/// 用户要的是「有变更时手机响一下」。App 已有 30 秒轮询 `/api/state`，
/// 在轮询结果里对比 event id 就能发现新变更，直接用 UNUserNotificationCenter
/// 发本地通知即可 —— 不依赖 Bark/Server酱，也不需要 APNs 证书和后端推送通道。
///
/// 局限（如实说明）：App 被系统彻底杀掉后不会轮询，那时的变更要等下次打开
/// App 才会补推。真正的后台实时推送需要 APNs + 服务端证书，是另一个量级的事。
///
/// iOS 16.1.1 兼容：UNUserNotificationCenter 是 iOS 10 起的 API，全部可用；
/// `.banner/.sound/.badge` 是 iOS 14+ 的呈现选项，16.1.1 完全支持。
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// 用户开关。默认开；持久化到 UserDefaults（TrollStore 侧载下 UserDefaults 可正常读写）。
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    /// 系统授权状态，用于设置页展示与引导
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private static let enabledKey = "sw_native_notify_enabled"
    private static let seenKey = "sw_seen_event_ids"
    private let center = UNUserNotificationCenter.current()

    override init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        center.delegate = self
    }

    // MARK: 权限

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// 首次进入或用户点「开启」时调用。返回是否获得授权。
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    /// 权限被拒时引导去系统设置
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: 变更检测

    /// 每次 state 刷新后调用：对比 event id，只推「新出现」的变更。
    /// 首次运行只记基线不推送，避免一登录就弹一堆历史事件。
    func observe(_ state: DashboardState) async {
        let ids = Set(state.cards.flatMap { $0.events.map(\.id) })
        let previous = Self.loadSeen()
        Self.saveSeen(ids)

        // 首次（无基线）：静默建立基线
        guard !previous.isEmpty else { return }
        let newIDs = ids.subtracting(previous)
        guard isEnabled, !newIDs.isEmpty else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        // 按目标聚合：哪几个账号有新动作
        let pairs: [(name: String, event: ChangeEvent)] = state.cards.flatMap { card in
            card.events.filter { newIDs.contains($0.id) }.map { (card.name, $0) }
        }
        let title = pairs.count == 1 ? "\(pairs[0].name) 有新变更" : "\(pairs.count) 条新变更"

        var lines: [String] = []
        for (name, ev) in pairs.prefix(3) {
            let what = ev.itemName ?? ev.scopeName ?? ev.tag
            lines.append("\(name)：\(ev.tag) \(what)")
        }
        if pairs.count > 3 { lines.append("还有 \(pairs.count - 3) 条…") }
        await send(title: title, body: lines.joined(separator: "\n"))
    }

    /// 手动清基线：下次刷新会重新建立，不推历史。用于「重置通知」。
    func resetBaseline() {
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
    }

    // MARK: 发送

    func sendTest() async {
        await send(title: "沃池", body: "原生通知已配置成功 ✅")
    }

    private func send(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)
        let request = UNNotificationRequest(
            identifier: "sw.\(UUID().uuidString)",
            content: content,
            trigger: nil   // 立即投递
        )
        try? await center.add(request)
    }

    /// App 回到前台时清掉角标
    func clearBadge() {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }

    // MARK: UNUserNotificationCenterDelegate

    /// App 在前台时也显示横幅（否则只有通知中心里能看到，用户感知不到）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
        // 前台收到通知时把刚加的角标清零：App 正开着，用户能直接看到内容，
        // 留一个角标在图标上没有任何意义，反而变成"清不掉"的死角。
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    /// 用户点击通知打开 App：立刻清角标。
    /// 这是"角标无法交互清除"的另一半——从通知中心点进来时，
    /// scenePhase 的 .active 变化未必被捕获（App 已在前台时），必须在这里兜底。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        completionHandler()
    }

    // MARK: 持久化基线

    private static func loadSeen() -> Set<Int> {
        guard let arr = UserDefaults.standard.array(forKey: seenKey) as? [Int] else { return [] }
        return Set(arr)
    }

    private static func saveSeen(_ ids: Set<Int>) {
        // 只留最近 500 个，避免 UserDefaults 里无限增长
        let trimmed = Array(ids.sorted(by: >).prefix(500))
        UserDefaults.standard.set(trimmed, forKey: seenKey)
    }
}
