import SwiftUI

/// 看板首页：目标卡片网格 + 状态栏。
/// 数据来自 DashboardViewModel（共享），30 秒轮询。
struct DashboardView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @State private var showTargets = false
    @State private var showLogin = false
    @State private var selectedCard: MonitorCard?
    @State private var toast: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBar
                    if let err = vm.errorText {
                        errorBanner(err)
                    }
                    cardsGrid
                }
                .padding(16)
            }
            .background(Color(red: 0.965, green: 0.965, blue: 0.955))
            .navigationTitle("监控看板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { Task { await vm.refresh() } }
            .task {
                vm.loadCached()          // 先显示上次缓存，秒开
                await vm.refresh()       // 再后台拉最新覆盖（失败则保留缓存）
                vm.startPolling()
            }
            .onDisappear { vm.stopPolling() }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showTargets) { TargetListView().environmentObject(vm) }
        .sheet(isPresented: $showLogin) { PlatformLoginView() }
        .sheet(item: $selectedCard) { card in
            ChangeRecordView(card: card).environmentObject(vm)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                Task { await vm.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(vm.isLoading)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    Task {
                        let msg = await vm.runCheck()
                        showToast(msg ?? "已触发巡检")
                    }
                } label: {
                    Label(vm.state?.check.running == true ? "巡检中…" : "立即巡检",
                          systemImage: "bolt")
                }
                .disabled(vm.state?.check.running == true)

                Divider()
                Button { showLogin = true } label: {
                    Label("平台登录", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button { showTargets = true } label: {
                    Label("目标管理", systemImage: "list.bullet.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                pill("目标 \(vm.state?.targets.count ?? 0)", icon: "target")
                if let interval = vm.state?.config.pollIntervalMinutes {
                    pill("每 \(interval) 分钟", icon: "clock")
                }
                if vm.state?.check.running == true {
                    pill("巡检中", icon: "bolt.fill", tone: .warn)
                } else {
                    pill("空闲", icon: "circle", tone: .muted)
                }
            }

            // 平台登录态徽章，点进去进扫码登录
            HStack(spacing: 8) {
                ForEach([Platform.netease, .weibo, .douyin, .xiaohongshu], id: \.self) { p in
                    Button { showLogin = true } label: {
                        let on = vm.state?.login.isLogged(p) == true
                        HStack(spacing: 4) {
                            Circle()
                                .fill(on ? Color(red: 0.18, green: 0.62, blue: 0.36)
                                         : Color.gray.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(p.label).font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color(.systemGray5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let updated = vm.lastUpdated {
                Text("更新于 \(timeText(updated))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func pill(_ text: String, icon: String, tone: PillTone = .normal) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundColor(tone == .warn ? Color(red: 0.72, green: 0.32, blue: 0.18)
                         : tone == .muted ? .secondary : .primary)
        .background(tone == .warn ? Color(red: 0.99, green: 0.94, blue: 0.88) : Color.white)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color(.systemGray5), lineWidth: 0.5))
    }

    private enum PillTone { case normal, warn, muted }

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundColor(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 卡片网格

    private var cardsGrid: some View {
        Group {
            if let state = vm.state, !state.cards.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(state.cards) { card in
                        CardTile(card: card)
                            .onTapGesture { selectedCard = card }
                    }
                }
            } else if vm.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
            } else {
                emptyCard
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 32))
                .foregroundColor(.gray.opacity(0.5))
            Text("还没有监控目标")
                .font(.system(size: 15, weight: .medium))
            Text("点右上角 ··· → 目标管理，添加要监控的账号")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("去添加") { showTargets = true }
                .font(.system(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - 卡片格子

struct CardTile: View {
    let card: MonitorCard

    /// 数字太大时缩写，避免两列网格里长数字换行（如 1,749 → 1.7k）
    private static func compactNumber(_ v: Int) -> String {
        if v >= 10000 { return String(format: "%.1fw", Double(v) / 10000.0) }
        if v >= 1000 { return String(format: "%.1fk", Double(v) / 1000.0) }
        return String(v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProxyImage(url: card.avatar, placeholderText: card.name, circular: true)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(card.platform)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if !card.enabled {
                    Text("停用").font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.gray.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if !card.sortedHead.isEmpty {
                HStack(spacing: 2) {
                    ForEach(card.sortedHead, id: \.key) { item in
                        VStack(spacing: 2) {
                            Text(Self.compactNumber(item.value))
                                .font(.system(size: card.sortedHead.count > 3 ? 14 : 16, weight: .medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(item.key)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if !card.stats.isEmpty {
                Divider()
                HStack(spacing: 4) {
                    ForEach(card.stats, id: \.label) { s in
                        statCell(s)
                    }
                }
            }

            HStack {
                Label("内容库 \(card.archive?.total ?? 0)", systemImage: "photo")
                if let del = card.archive?.deleted, del > 0 {
                    Text("· 已删 \(del)")
                }
                Spacer()
                Text("变更 \(card.events.count) ›")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            // 上次更新时间取代原来的「最近巡检」列表，信息密度更高
            if let t = card.lastRunTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                    Text("上次更新 \(shortTime(t))")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 0.5)
        )
    }

    /// 后端给 "2026-11-21 12:54"，卡片窄，只显示 "11-21 12:54"
    private func shortTime(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return s }
        let date = parts[0].split(separator: "-")
        if date.count == 3 { return "\(date[1])-\(date[2]) \(parts[1])" }
        return s
    }

    private func statCell(_ s: StatTriple) -> some View {
        VStack(spacing: 2) {
            Text(s.valueText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundColor(s.isAdd ? Color(red: 0.75, green: 0.28, blue: 0.22)
                                 : s.style == "del" ? Color(red: 0.16, green: 0.5, blue: 0.31)
                                 : .primary)
            Text(s.label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(run.isOK ? Color(red: 0.2, green: 0.6, blue: 0.36) : .red)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(run.target ?? "全局").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(run.time).font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let msg = run.message, !msg.isEmpty {
                    Text(msg).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
    }
}
