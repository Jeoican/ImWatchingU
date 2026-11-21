import SwiftUI

/// 平台扫码登录：后端起浏览器 → 每 1 秒轮询状态 → 有新截图就取 base64 显示。
/// 注意这是「采集凭证」登录（让后端能抓数据），不是 App 自身账号登录。
struct PlatformLoginView: View {
    @Environment(\.presentationMode) private var presentation

    @State private var platform: String = "weibo"
    @State private var phase: Phase = .idle
    @State private var shotImage: UIImage?
    @State private var statusText = ""
    @State private var lastShotAt: Int?
    @State private var pollTask: Task<Void, Never>?
    @State private var message: String?

    private let platforms: [(String, String)] = [
        ("weibo", "微博"), ("netease", "网易云"), ("douyin", "抖音"), ("xiaohongshu", "小红书")
    ]

    private enum Phase { case idle, starting, waiting, success, failed }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("为采集凭证登录。登录后后端才能读取该平台的账号数据。")
                    .font(.system(size: 13)).foregroundColor(.secondary)

                Picker("平台", selection: $platform) {
                    ForEach(platforms, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .disabled(phase == .waiting || phase == .starting)

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.96, green: 0.96, blue: 0.95))
                    if let img = shotImage {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                            .padding(8)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 44)).foregroundColor(.gray.opacity(0.5))
                            Text(statusText.isEmpty ? "点「开始登录」后显示扫码画面" : statusText)
                                .font(.system(size: 13)).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                if !statusText.isEmpty {
                    HStack {
                        Image(systemName: phase == .success ? "checkmark.circle.fill"
                              : phase == .failed ? "xmark.circle.fill" : "info.circle")
                        Text(statusText).font(.system(size: 13))
                    }
                    .foregroundColor(phase == .success ? Color(red: 0.18, green: 0.6, blue: 0.36)
                                     : phase == .failed ? .red : .secondary)
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundColor(.red)
                }

                Spacer()

                HStack(spacing: 12) {
                    if phase == .waiting || phase == .starting {
                        Button("取消") { Task { await cancel() } }
                            .frame(maxWidth: .infinity)
                    } else {
                        Button(phase == .failed ? "重新登录" : "开始登录") {
                            Task { await start() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .navigationTitle("平台登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
            .onDisappear { pollTask?.cancel() }
        }
        .navigationViewStyle(.stack)
    }

    private func start() async {
        message = nil
        phase = .starting
        statusText = "正在启动浏览器…"
        do {
            let r = try await APIClient.shared.startLoginFlow(platform: platform)
            if !r.ok {
                phase = .failed
                message = r.message ?? "启动失败"
                return
            }
            phase = .waiting
            startPolling()
        } catch let e as APIError {
            phase = .failed
            message = e.errorDescription
        } catch {
            phase = .failed
            message = error.localizedDescription
        }
    }

    private func cancel() async {
        pollTask?.cancel()
        pollTask = nil
        do { _ = try await APIClient.shared.cancelLoginFlow(platform: platform) } catch {}
        phase = .idle
        statusText = "已取消"
        shotImage = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                let status = try? await APIClient.shared.loginFlowStatus(platform: self.platform)
                if let status {
                    await self.apply(status: status)
                    let state = status.state ?? ""
                    if state == "success" || state == "failed" || state == "cancelled" { break }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @MainActor
    private func apply(status: LoginFlowStatus) async {
        if let msg = status.message, !msg.isEmpty { statusText = msg }
        switch status.state ?? "" {
        case "success":
            phase = .success
            statusText = status.message ?? "登录成功"
            pollTask?.cancel()
        case "failed":
            phase = .failed
            statusText = status.message ?? status.error ?? "登录失败"
            pollTask?.cancel()
        case "cancelled":
            phase = .idle
            statusText = "已取消"
            pollTask?.cancel()
        default:
            // waiting：有新截图才拉，避免每秒下同一张
            if status.hasShot == true, status.shotAt != lastShotAt {
                lastShotAt = status.shotAt
                if let shot = try? await APIClient.shared.loginFlowShot(platform: platform),
                   let b64 = shot.shot,
                   let data = Data(base64Encoded: b64) {
                    shotImage = UIImage(data: data)
                }
            }
        }
    }
}
