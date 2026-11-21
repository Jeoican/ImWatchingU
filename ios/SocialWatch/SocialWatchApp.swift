import SwiftUI

@main
struct SocialWatchApp: App {
    @StateObject private var session = AppSession()
    /// 监听 App 生命周期：回到前台时清角标。只靠 onAppear 不够——
    /// App 从后台恢复时 onAppear 不会再次触发，角标就会一直挂着。
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                // 固定浅色：web 端的设计基线就是浅色纸面感，
                // 深色模式会让大量 #f4f4f2 这类硬编码色块突兀。
                // 等真正做深色适配时再放开，不要现在半途而废。
                .preferredColorScheme(.light)
                .onAppear {
                    // 原生通知：刷新授权状态（用户可能在系统设置里改过），清掉角标。
                    // 首次安装不主动弹权限框 —— 等设置页用户点「开启」再申请，
                    // 避免一上来就弹窗打断登录流程。
                    Task {
                        await NotificationManager.shared.refreshAuthorization()
                    }
                    NotificationManager.shared.clearBadge()
                    #if DEBUG
                    // 仅调试期：主动打一枪后端，把结果写进系统日志。
                    StartupProbe.run()
                    #endif
                }
                // 从后台/锁屏点通知回到前台：清角标。这是角标"清不掉"的主因。
                .onChange(of: scenePhase) { phase in
                    if phase == .active { NotificationManager.shared.clearBadge() }
                }
        }
    }
}

/// 全局会话状态。
///
/// 这里只放「跨屏共享」的东西：凭证、解锁状态、当前目标。
/// 列表数据不放在这里 —— 它会随滚动不断追加，放进全局会造成
/// 无关视图跟着刷新，那是 SwiftUI 里最常见的性能坑。
@MainActor
final class AppSession: ObservableObject {
    @Published var isConfigured: Bool
    @Published var isUnlocked: Bool = false
    @Published var authError: String?

    init() {
        let cred = CredentialStore.shared.load()
        isConfigured = cred?.isConfigured ?? false
        // 没配置凭证时不需要解锁，直接进配置页
        isUnlocked = false

        #if DEBUG
        // 自动化验证通道：模拟器里没有 Face ID，也无法用脚本点按钮，
        // 所以留一个仅 DEBUG 生效的环境变量旁路，用于端到端截图验证。
        // 用 `SIMCTL_CHILD_SW_SKIP_LOCK=1 xcrun simctl launch ...` 触发。
        // Release 构建不含这段代码，真机不存在任何绕过门禁的可能。
        if ProcessInfo.processInfo.environment["SW_SKIP_LOCK"] == "1", isConfigured {
            isUnlocked = true
        }
        #endif
    }

    func markConfigured(_ v: Bool) {
        isConfigured = v
        if !v { isUnlocked = false }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var dashboard = DashboardViewModel()

    var body: some View {
        Group {
            if !session.isConfigured {
                LoginView()
            } else if !session.isUnlocked {
                LockView()
            } else {
                MainTabView()
                    .environmentObject(dashboard)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isConfigured)
        .animation(.easeInOut(duration: 0.25), value: session.isUnlocked)
        // Token 失效：退回配置页让用户重新填
        .onChange(of: dashboard.unauthorized) { bad in
            if bad {
                CredentialStore.shared.clear()
                session.markConfigured(false)
            }
        }
    }
}

/// 主导航。看板 / 内容库 / 设置 三个 Tab。
/// 保留原来的 DEBUG 旁路：设了 SW_DEBUG_ITEM 就直接进详情页，方便无点击工具时验证。
struct MainTabView: View {
    #if DEBUG
    @State private var debugDetail: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["SW_DEBUG_ITEM"] else { return nil }
        return Int(raw)
    }()
    /// 自动化验证：SW_TAB=archive|settings 直接选中对应 tab（无点击工具时用）
    @State private var debugTab: Int = {
        switch ProcessInfo.processInfo.environment["SW_TAB"] {
        case "archive": return 1
        case "settings": return 2
        default: return 0
        }
    }()
    #endif

    #if DEBUG
    private var tabSelection: Binding<Int> { $debugTab }
    #else
    private var tabSelection: Binding<Int> { .constant(0) }
    #endif

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SW_DEBUG_MUSIC"] == "1" {
            NavigationView { PlaylistListView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
        } else if ProcessInfo.processInfo.environment["SW_DEBUG_MUSIC"] == "songs" {
            NavigationView {
                SongListView(playlist: MusicPlaylist(
                    targetKey: "netease:316198477", targetName: "云朵也会有烦恼",
                    id: "439449787", name: "云朵也会有烦恼喜欢的音乐",
                    cover: nil, trackCount: 1033))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
        } else if let id = debugDetail {
            NavigationView {
                ArchiveDetailView(itemID: id)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("关闭") { debugDetail = nil }
                        }
                    }
            }
        } else {
            tabView
        }
        #else
        tabView
        #endif
    }

    private var tabView: some View {
        TabView(selection: tabSelection) {
            DashboardView()
                .tabItem {
                    Label("看板", systemImage: "square.grid.2x2")
                }
                .tag(0)
            ArchiveListView()
                .tabItem {
                    Label("内容库", systemImage: "photo.stack")
                }
                .tag(1)
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(2)
        }
        .accentColor(Color(red: 0.82, green: 0.28, blue: 0.22))
        // 迷你播放条贴在 TabBar 上方，任何页面都能看到正在播放的歌
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
        }
    }
}
