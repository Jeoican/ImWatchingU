import SwiftUI

/// 目标管理：列出所有监控目标，支持添加/编辑/启停/删除。
struct TargetListView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @Environment(\.presentationMode) private var presentation

    @State private var editing: MonitorTarget?
    @State private var showAdd = false
    @State private var confirmDelete: MonitorTarget?
    @State private var toast: String?

    var body: some View {
        NavigationView {
            List {
                if let err = vm.errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundColor(.red)
                    }
                }
                Section {
                    ForEach(vm.state?.targets ?? []) { t in
                        targetRow(t)
                    }
                } header: {
                    Text("监控目标 \(vm.state?.targets.count ?? 0)")
                }
                Section {
                    Button {
                        Task { await vm.refresh() }
                    } label: {
                        HStack { Spacer(); Text("刷新"); Spacer() }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("目标管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                TargetEditView(existing: nil).environmentObject(vm)
            }
            .sheet(item: $editing) { t in
                TargetEditView(existing: t).environmentObject(vm)
            }
            .alert(item: $confirmDelete) { t in
                Alert(
                    title: Text("删除目标"),
                    message: Text("确定删除「\(t.name)」？历史数据会保留。"),
                    primaryButton: .destructive(Text("删除")) {
                        Task { let msg = await vm.deleteTarget(t); showToast(msg ?? "已删除") }
                    },
                    secondaryButton: .cancel()
                )
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 14))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.82)).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 24).transition(.opacity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                withAnimation { self.toast = nil }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func targetRow(_ t: MonitorTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: t.enabled ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(t.enabled ? Color(red: 0.18, green: 0.6, blue: 0.36) : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 15, weight: .medium))
                    Text("\(t.platformEnum.label) · \(t.id)")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Button {
                    Task { let msg = await vm.setTargetEnabled(t, enabled: !t.enabled); showToast(msg ?? "已更新") }
                } label: {
                    Text(t.enabled ? "停用" : "启用").font(.system(size: 12))
                }
                Button { editing = t } label: {
                    Text("编辑").font(.system(size: 12))
                }
                Button {
                    Task {
                        let msg = await vm.runCheck(target: t.targetID)
                        showToast(msg ?? "已巡检")
                    }
                } label: {
                    Text("巡检").font(.system(size: 12))
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = t } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(.systemBlue))
        }
        .padding(.vertical, 4)
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
    }
}

// MARK: - 添加/编辑

struct TargetEditView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @Environment(\.presentationMode) private var presentation
    let existing: MonitorTarget?

    @State private var platform: String = "weibo"
    @State private var accountID: String = ""
    @State private var name: String = ""
    @State private var linkText: String = ""
    @State private var peopleFollowing = false
    @State private var peopleFollowers = false
    @State private var maxUsersText: String = "500"
    @State private var enabled = true
    @State private var message: String?
    @State private var isSaving = false
    @State private var isResolving = false

    private let platforms: [(String, String)] = [
        ("weibo", "微博"), ("netease", "网易云"), ("douyin", "抖音"), ("xiaohongshu", "小红书")
    ]

    var body: some View {
        NavigationView {
            Form {
                Section("平台") {
                    Picker("平台", selection: $platform) {
                        ForEach(platforms, id: \.0) { p in Text(p.1).tag(p.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("主页链接（可选，自动识别）") {
                    TextField("粘贴主页链接后自动识别平台与 ID", text: $linkText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 14))
                        .onChange(of: linkText) { newValue in
                            if newValue.contains("http") { Task { await resolve(newValue) } }
                        }
                    if isResolving {
                        HStack { ProgressView().scaleEffect(0.7); Text("识别中…").font(.system(size: 12)) }
                    }
                }
                Section("账号") {
                    TextField("账号 ID", text: $accountID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备注名（可选）", text: $name)
                }
                Section("精确到人") {
                    Toggle("关注列表", isOn: $peopleFollowing)
                    Toggle("粉丝列表", isOn: $peopleFollowers)
                    HStack {
                        Text("最多读取人数").font(.system(size: 14))
                        Spacer()
                        TextField("500", text: $maxUsersText)
                            .keyboardType(.numberPad).frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if existing != nil {
                    Section { Toggle("启用该目标", isOn: $enabled) }
                }
                if let message {
                    Section { Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundColor(.red) }
                }
            }
            .navigationTitle(existing == nil ? "添加目标" : "编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isSaving ? "保存中" : "保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                if let t = existing {
                    platform = t.platform
                    accountID = t.id
                    name = t.name
                    enabled = t.enabled
                    peopleFollowing = t.options.people.contains("following")
                    peopleFollowers = t.options.people.contains("followers")
                    if let m = t.options.maxUsers { maxUsersText = String(m) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func resolve(_ url: String) async {
        isResolving = true
        do {
            let r = try await APIClient.shared.resolveLink(url)
            if r.ok, let p = r.platform, let i = r.id {
                platform = p
                accountID = i
            }
        } catch { /* 识别失败不打扰，用户可手动填 */ }
        isResolving = false
    }

    private func save() async {
        guard !accountID.isEmpty else {
            message = "请填账号 ID（或先用主页链接自动识别）"
            return
        }
        isSaving = true
        message = nil
        var people: [String] = []
        if peopleFollowing { people.append("following") }
        if peopleFollowers { people.append("followers") }
        let maxU = Int(maxUsersText)

        do {
            let r: OKResponse
            if let t = existing {
                r = try await APIClient.shared.updateTarget(
                    index: t.index, platform: platform, id: accountID, name: name,
                    enabled: enabled, people: people, maxUsers: maxU)
            } else {
                r = try await APIClient.shared.addTarget(
                    platform: platform, id: accountID, name: name,
                    people: people, maxUsers: maxU)
            }
            if r.ok {
                await vm.refresh()
                presentation.wrappedValue.dismiss()
            } else {
                message = r.message ?? "保存失败"
            }
        } catch let e as APIError {
            message = e.errorDescription
        } catch {
            message = error.localizedDescription
        }
        isSaving = false
    }
}
