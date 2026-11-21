import SwiftUI
import LocalAuthentication

/// 首次配置：服务器地址 + Token。
///
/// 一个刻意的设计：Face ID 不参与鉴权
/// ----------------------------------
/// `LocalAuthentication` 只返回一个布尔值，纯本地判断，服务端无法验证。
/// 它只是「门禁」——防止手机借给别人时被随手打开，真正的凭证仍然是 Token。
/// 所以这个页面负责收 Token，LockView 负责用 Face ID 守住已存的 Token。
struct LoginView: View {
    @EnvironmentObject private var session: AppSession

    // 预填 NAS 地址。域名 → 自动补 https，走正式证书。
    // 用户只需再填 Token；密码类凭证绝不写进 App。
    @State private var baseURL: String = "jeoi.tech:5671"
    @State private var token: String = ""
    @State private var message: String = ""
    @State private var isChecking = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器地址")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("jeoi.tech:5671 或 192.168.1.5:8080", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.system(size: 16, design: .monospaced))
                            .padding(12)
                            .background(fieldBackground)
                        // 明确写出 scheme 规则，避免用户踩「裸 IP 被补成 https → SSL 错误」的坑
                        Text("填 IP 自动用 http，填域名自动用 https；也可手动写完整地址。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("访问 Token")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        // font 用 16pt 而不是更小：iOS 在 <16pt 的输入框获得焦点时
                        // 会自动放大整页，那一下缩放会打断输入。
                        SecureField("sw_xxxxxxxx", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced))
                            .padding(12)
                            .background(fieldBackground)
                        Text("在电脑上执行 `cli token issue -n iphone14pro` 生成。明文只显示一次。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    if !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }

                    Button(action: save) {
                        HStack {
                            if isChecking { ProgressView().tint(.white) }
                            Text(isChecking ? "验证中…" : "保存并验证")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)          // >= 44pt，符合触控最小目标
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isChecking || baseURL.isEmpty || token.isEmpty)

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .navigationTitle("连接服务器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("沃池")
                .font(.system(size: 26, weight: .bold))
            Text("私人社媒存档")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(red: 0.96, green: 0.96, blue: 0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.88, green: 0.88, blue: 0.86), lineWidth: 1)
            )
    }

    private func save() {
        message = ""
        let cred = Credentials(
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespaces)
        )
        guard cred.isConfigured else {
            message = "地址与 Token 都不能为空"
            return
        }
        guard let url = cred.normalizedBaseURL, url.scheme?.hasPrefix("http") == true else {
            message = "地址格式不对，应形如 https://sw.example.com"
            return
        }

        isChecking = true
        Task {
            do {
                try CredentialStore.shared.save(cred)
                // verifyAuth 打的是 /api/auth/status（不需要鉴权），
                // 所以它只能验证「地址可达」，验证不了 Token。
                // 真正的验证放在下面：用一个需要鉴权的请求试。
                _ = try await APIClient.shared.archiveList(limit: 1)
                await MainActor.run {
                    session.markConfigured(true)
                    session.isUnlocked = true
                    isChecking = false
                }
            } catch let e as APIError {
                // 验证失败就把凭证清掉，避免存着一个错的然后每次 401
                CredentialStore.shared.clear()
                await MainActor.run {
                    message = e.errorDescription ?? "连接失败"
                    isChecking = false
                }
            } catch {
                CredentialStore.shared.clear()
                await MainActor.run {
                    message = error.localizedDescription
                    isChecking = false
                }
            }
        }
    }
}

/// 已配置凭证后的门禁页。
///
/// Face ID 必须提供「无法使用」时的退路：模拟器没有 Face ID、
/// 用户可能没设密码、硬件可能不可用。直接卡死在这里是最糟的体验。
struct LockView: View {
    @EnvironmentObject private var session: AppSession

    @State private var message: String = ""
    @State private var isEvaluating = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "faceid")
                .font(.system(size: 64))
                .foregroundColor(Color.accentColor)

            VStack(spacing: 8) {
                Text("已锁定")
                    .font(.system(size: 22, weight: .semibold))
                Text("用 Face ID 解锁私人存档")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: unlock) {
                    HStack {
                        if isEvaluating { ProgressView().tint(.white) }
                        Text(isEvaluating ? "验证中…" : "解锁")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isEvaluating)

                // 退路：设备无 Face ID / 模拟器 / 硬件不可用时，
                // 不该把人锁死在外面。
                Button("直接进入（不使用 Face ID）") {
                    session.isUnlocked = true
                }
                .font(.system(size: 14))
                .foregroundColor(.secondary)

                Button("重新配置服务器") {
                    session.markConfigured(false)
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
        .onAppear {
            // 刻意不在 onAppear 自动调起系统验证。
            // 曾经的写法是「进来就自动弹一次，省一次点击」，实测在带密码的设备上
            // 会直接盖一层系统密码框，把整个界面（包括下面的退路按钮）全遮住 ——
            // 一次弹窗失败就等于进不去。自动验证必须在用户主动点击时才发生。
        }
    }

    private func unlock() {
        guard !isEvaluating else { return }
        message = ""

        let ctx = LAContext()
        var err: NSError?

        // 优先纯生物识别：Face ID 在 iPhone 14 Pro 上是一次抬眼的体验。
        // 不用 .deviceOwnerAuthentication，是因为它会在没有生物识别时
        // 直接弹系统密码框，而那个框我们控制不了层级，容易变成死路。
        let policy: LAPolicy
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            // 无 Face ID 但有设备密码（模拟器常见）：让用户明确知道
            // 接下来会弹密码框，而不是被突然挡住。
            policy = .deviceOwnerAuthentication
        } else {
            message = "此设备不支持生物识别或设备密码，请用下方按钮进入"
            return
        }

        isEvaluating = true
        ctx.evaluatePolicy(policy, localizedReason: "解锁私人社媒存档") { ok, evalErr in
            DispatchQueue.main.async {
                isEvaluating = false
                if ok {
                    session.isUnlocked = true
                } else {
                    message = evalErr?.localizedDescription ?? "验证未通过"
                }
            }
        }
    }
}
