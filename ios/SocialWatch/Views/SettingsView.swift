import SwiftUI

/// 设置页：服务器信息、重新配置凭证、关于。
struct SettingsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var vm: DashboardViewModel
    @ObservedObject private var notify = NotificationManager.shared
    @State private var showReloginConfirm = false
    @State private var notifyMessage: String?
    // 从看板顶栏迁过来的三个入口
    @State private var showTargets = false
    @State private var showLogin = false
    @State private var checkMessage: String?
    @State private var isChecking = false

    private var cred: Credentials? { CredentialStore.shared.load() }

    private var permissionLabel: String {
        switch notify.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "已授权"
        case .denied: return "被拒绝 · 去系统设置开启"
        default: return "未开启 · 点此授权"
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("服务器") {
                    HStack {
                        Text("地址").foregroundColor(.secondary)
                        Spacer()
                        Text(cred?.normalizedBaseURL?.absoluteString ?? "未配置")
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                    }
                    HStack {
                        Text("状态").foregroundColor(.secondary)
                        Spacer()
                        if vm.isLoading {
                            ProgressView().scaleEffect(0.7)
                        } else if vm.errorText == nil {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .foregroundColor(Color(red: 0.18, green: 0.6, blue: 0.36))
                                .font(.system(size: 13))
                        } else {
                            Label("异常", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red).font(.system(size: 13))
                        }
                    }
                    Button { Task { await vm.refresh() } } label: {
                        HStack { Image(systemName: "arrow.clockwise"); Text("重新连接") }
                    }
                }

                Section("通知") {
                    Toggle("变更时提醒", isOn: $notify.isEnabled)
                    if notify.isEnabled {
                        Button {
                            Task {
                                if notify.authorizationStatus == .denied {
                                    notify.openSystemSettings()
                                } else {
                                    await notify.requestPermission()
                                }
                                await notify.refreshAuthorization()
                            }
                        } label: {
                            HStack {
                                Label(permissionLabel, systemImage: "bell.badge")
                                Spacer()
                                if notify.authorizationStatus == .authorized || notify.authorizationStatus == .provisional {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color(red: 0.18, green: 0.6, blue: 0.36))
                                }
                            }
                            .font(.system(size: 14))
                        }
                        Button {
                            Task {
                                await notify.sendTest()
                                notifyMessage = "测试通知已发送，看通知中心"
                            }
                        } label: {
                            Label("发送测试通知", systemImage: "paperplane")
                        }
                    }
                    if let msg = notifyMessage {
                        Text(msg).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Text("App 每 30 秒检查一次新变更；App 完全退出期间不推送。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                Section("管理") {
                    // 立即巡检（原看板顶栏 ··· 菜单）
                    Button {
                        Task {
                            guard !isChecking else { return }
                            isChecking = true
                            let msg = await vm.runCheck()
                            await MainActor.run {
                                checkMessage = msg ?? "已触发巡检"
                                isChecking = false
                            }
                        }
                    } label: {
                        HStack {
                            Label(isChecking ? "巡检中…" : "立即巡检", systemImage: "bolt")
                            Spacer()
                            if isChecking { ProgressView().scaleEffect(0.7) }
                        }
                    }
                    .disabled(isChecking || vm.state?.check.running == true)

                    // 平台登录（原看板顶栏 ··· 菜单 + 状态栏徽章）
                    Button { showLogin = true } label: {
                        Label("平台登录", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    // 目标管理（原看板顶栏 ··· 菜单 + 空状态「去添加」）
                    Button { showTargets = true } label: {
                        Label("目标管理", systemImage: "list.bullet.circle")
                    }
                    if let msg = checkMessage {
                        Text(msg).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }

                Section("账号") {
                    Button(role: .destructive) { showReloginConfirm = true } label: {
                        Label("退出并重新配置", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section {
                    HStack {
                        Text("版本").foregroundColor(.secondary)
                        Spacer()
                        Text("1.0").foregroundColor(.secondary)
                    }
                    Text("沃池 · 社媒变更监控")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } footer: {
                    Text("服务器地址为内网 IP 时自动用 http，域名用 https。NAS 地址 jeoi.tech:5671。Token 只保存在本机，密码不会写入 App。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .sheet(isPresented: $showTargets) { TargetListView().environmentObject(vm) }
            .sheet(isPresented: $showLogin) { PlatformLoginView() }
            .alert("退出登录", isPresented: $showReloginConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    CredentialStore.shared.clear()
                    session.markConfigured(false)
                }
            } message: {
                Text("清除本机 Token 并回到配置页。历史数据不受影响。")
            }
        }
        .navigationViewStyle(.stack)
    }
}
