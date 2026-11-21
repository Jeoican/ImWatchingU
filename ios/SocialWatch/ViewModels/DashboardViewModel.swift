import Foundation
import SwiftUI

/// 看板数据中枢。持有一份 `/api/state`，供看板/目标/通知各页共享。
///
/// 为什么放 ObservableObject 而不是各视图各自请求：
///   - /api/state 是聚合接口，一次拉全，重复请求浪费（后端还有短缓存）；
///   - 30 秒轮询只有一处定时器，切 Tab 不打断；
///   - 写操作（巡检/增删改目标）成功后统一 `refresh()`，各页自动同步。
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var state: DashboardState?
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var lastUpdated: Date?

    /// 401 时置 true，由 RootView 弹重新登录提示
    @Published var unauthorized = false

    private var refreshTask: Task<Void, Never>?
    private let cacheKey = "dashboard:state"

    /// 冷启动先灌缓存：用户一进看板就有内容，不等网络。
    /// 30 秒轮询/下拉刷新会在 refresh() 里覆盖成最新值。
    func loadCached() {
        guard state == nil else { return }
        state = DataCache.load(cacheKey, as: DashboardState.self, maxAge: 7 * 24 * 3600)
    }

    deinit { refreshTask?.cancel() }

    func refresh() async {
        if isLoading { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let s = try await APIClient.shared.dashboardState()
            state = s
            lastUpdated = Date()
            DataCache.save(cacheKey, value: s)
            // 新变更 → 原生本地通知。放在解码成功后，失败时不误报。
            await NotificationManager.shared.observe(s)
        } catch APIError.unauthorized {
            unauthorized = true
        } catch let e as APIError {
            errorText = e.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 启动 30 秒轮询。登录检测中（_checking）时后端可能还没就绪，
    /// 8 秒后补一次快速重试，与 web 端节奏一致。
    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let seconds = self.state?.login.checking == true ? 8 : 30
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: 写操作

    func runCheck(target: String? = nil) async -> String? {
        do {
            let r = try await APIClient.shared.runCheck(target: target)
            await refresh()
            return r.message ?? (target == nil ? "已触发巡检" : "已巡检该目标")
        } catch let e as APIError {
            return e.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    func setTargetEnabled(_ t: MonitorTarget, enabled: Bool) async -> String? {
        do {
            let r = try await APIClient.shared.setTargetEnabled(index: t.index, enabled: enabled)
            await refresh()
            return r.message
        } catch let e as APIError {
            return e.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    func deleteTarget(_ t: MonitorTarget) async -> String? {
        do {
            let r = try await APIClient.shared.deleteTarget(index: t.index)
            await refresh()
            return r.message
        } catch let e as APIError {
            return e.errorDescription
        } catch {
            return error.localizedDescription
        }
    }
}
