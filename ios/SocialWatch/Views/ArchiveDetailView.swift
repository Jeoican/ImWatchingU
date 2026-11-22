import SwiftUI
import Photos

/// 单条内容详情。
///
/// 统一样式（用户要求）：所有平台都按微博那套展示——
/// 头像/昵称/时间 → 正文（#话题#、@用户 蓝色高亮）→ 九宫格方图
/// → 转发/评论/点赞三栏 → 作者互动评论 → 归档元信息。
/// 小红书/抖音/网易云不再各用一套，视觉与交互完全一致，便于横向对照。
/// （xhsDetail / genericDetail 暂留作备份，当前不启用。）
///
/// 图片只用 thumb=1（900px ~105KB），进详情 0.4 秒内九宫格全可见；
/// 点开全屏才拉原图。绝不首屏拉 4MB 原图。
struct ArchiveDetailView: View {
    let itemID: Int

    @State private var detail: ArchiveDetail?
    @State private var errorText: String?
    @State private var fullscreenIndex: FullscreenSelection?

    private struct FullscreenSelection: Identifiable { let id: Int }

    var body: some View {
        ScrollView {
            if let detail {
                content(for: detail)
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .padding(24)
            } else {
                ProgressView().padding(48)
            }
        }
        .navigationTitle(detail?.platform?.label ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            #if DEBUG
            // 自动化验证通道：模拟器无法注入点击，靠 env 直接打开全屏看图，
            // 用于核对原图画质、无白边、单击/下滑退出。Release 无此代码。
            if ProcessInfo.processInfo.environment["SW_DEBUG_IMAGE"] == "1",
               let d = detail, !d.media.isEmpty, fullscreenIndex == nil {
                fullscreenIndex = FullscreenSelection(id: 0)
            }
            #endif
        }
        .fullScreenCover(item: $fullscreenIndex) { sel in
            if let detail {
                ImageViewer(media: detail.media, startIndex: sel.id, itemID: detail.id)
            }
        }
    }

    // MARK: - 平台分支

    @ViewBuilder
    private func content(for d: ArchiveDetail) -> some View {
        // 所有平台统一用微博样式；不再按平台分流。
        weiboDetail(d)
    }

    // MARK: - 微博

    private func weiboDetail(_ d: ArchiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            authorHeader(d)
            richText(d.cleanText)
                .font(.system(size: 16))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if let rt = d.retweetText, !rt.isEmpty {
                retweetBlock(rt)
            }
            if !d.media.isEmpty { weiboGrid(d) }
            actionBar(d, style: .weibo)
            if !d.comments.isEmpty { commentsBlock(d) }
            archiveMeta(d)
        }
        .padding(16)
    }

    /// 微博九宫格：1 张按原比例，2/4 张两列，其余三列；多图格子正方形填充。
    private func weiboGrid(_ d: ArchiveDetail) -> some View {
        let n = d.media.count
        let cols = (n == 1 || n == 2 || n == 4) ? n : 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols),
            spacing: 4
        ) {
            ForEach(Array(d.media.enumerated()), id: \.element.id) { idx, m in
                Button { fullscreenIndex = FullscreenSelection(id: idx) } label: {
                    WeiboGridImage(itemID: d.id, seq: m.seq,
                                   aspect: n == 1 ? m.aspectRatio : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 小红书

    private func xhsDetail(_ d: ArchiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            authorHeader(d)
            // 小红书笔记：首行往往是标题，加粗放大
            if let (title, rest) = splitTitle(d.cleanText) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !rest.isEmpty {
                    richText(rest)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                richText(d.cleanText)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.media.isEmpty { xhsGallery(d) }
            actionBar(d, style: .xhs)
            if !d.comments.isEmpty { commentsBlock(d) }
            archiveMeta(d)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    /// 小红书大图：整宽、按原始比例逐张排列（竖向长图也完整展示）。
    private func xhsGallery(_ d: ArchiveDetail) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(Array(d.media.enumerated()), id: \.element.id) { idx, m in
                Button { fullscreenIndex = FullscreenSelection(id: idx) } label: {
                    RemoteImage(itemID: d.id, seq: m.seq, tier: .detail,
                                aspectRatio: m.aspectRatio)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 通用（抖音/网易云/未知）

    private func genericDetail(_ d: ArchiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            authorHeader(d)
            richText(d.cleanText)
                .font(.system(size: 16))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if let rt = d.retweetText, !rt.isEmpty { retweetBlock(rt) }
            if !d.media.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(Array(d.media.enumerated()), id: \.element.id) { idx, m in
                        Button { fullscreenIndex = FullscreenSelection(id: idx) } label: {
                            RemoteImage(itemID: d.id, seq: m.seq, tier: .detail,
                                        aspectRatio: m.aspectRatio)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            actionBar(d, style: .weibo)
            if !d.comments.isEmpty { commentsBlock(d) }
            archiveMeta(d)
        }
        .padding(16)
    }

    // MARK: - 通用组件

    /// 作者栏：头像（昵称首字占位，后端未返回单条头像）+ 昵称 + 时间 + 平台原址入口。
    private func authorHeader(_ d: ArchiveDetail) -> some View {
        HStack(spacing: 10) {
            avatar(d)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.authorName?.isEmpty == false ? d.authorName! : "未知用户")
                    .font(.system(size: 14, weight: .semibold))
                Text(fmtTime(d.postedDate))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if let urlStr = d.url, let url = URL(string: urlStr) {
                Link(destination: url) {
                    Text("查看原文")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundColor(.white)
                        .background(Color(red: 0.92, green: 0.27, blue: 0.29))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func avatar(_ d: ArchiveDetail) -> some View {
        ProxyImage(url: d.authorAvatar,
                   placeholderText: d.authorName ?? "?",
                   circular: true)
            .frame(width: 42, height: 42)
            .overlay(
                Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5)
            )
    }

    /// 正文高亮：#话题# / #话题（小红书）、@用户 着蓝色，其余保持主色。
    private func richText(_ raw: String) -> Text {
        let pattern = "#[^#\\n]+#|@[\\u4e00-\\u9fa5A-Za-z0-9_]+"
        let regex = try? NSRegularExpression(pattern: pattern)
        let ns = raw as NSString
        var result = Text("")
        var last = raw.startIndex
        if let regex {
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: raw) else { continue }
                if range.lowerBound > last {
                    result = result + Text(String(raw[last..<range.lowerBound]))
                }
                result = result + Text(String(raw[range]))
                    .foregroundColor(Color(red: 0.13, green: 0.42, blue: 0.78))
                last = range.upperBound
            }
        }
        if last < raw.endIndex {
            result = result + Text(String(raw[last...]))
        }
        return result
    }

    /// 拆首行做小红书标题：首行较短且非纯话题串时才当标题。
    private func splitTitle(_ text: String) -> (String, String)? {
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        let title = String(text[text.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: nl)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 40, !rest.isEmpty else { return nil }
        return (title, rest)
    }

    private func retweetBlock(_ text: String) -> some View {
        richText(text)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundColor(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.96, green: 0.96, blue: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private enum ActionStyle { case weibo, xhs }

    private func actionBar(_ d: ArchiveDetail, style: ActionStyle) -> some View {
        HStack(spacing: 0) {
            switch style {
            case .weibo:
                actionItem(icon: "arrow.2.squarepath", count: d.reposts, label: "转发")
                actionItem(icon: "bubble.right", count: d.commentsCount, label: "评论")
                actionItem(icon: "heart", count: d.likes, label: "赞")
            case .xhs:
                actionItem(icon: "heart", count: d.likes, label: "赞")
                actionItem(icon: "bookmark", count: nil, label: "收藏")
                actionItem(icon: "bubble.right", count: d.commentsCount, label: "评论")
            }
        }
        .padding(.vertical, 12)
        .overlay(
            VStack(spacing: 0) {
                Divider()
                Spacer()
                Divider()
            }
        )
    }

    private func actionItem(icon: String, count: Int?, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15))
            Text(count.map { $0 > 0 ? compactCount($0) : label } ?? label)
                .font(.system(size: 12))
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func commentsBlock(_ d: ArchiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("作者互动 · \(d.comments.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(Array(d.comments.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        Circle().fill(Color(red: 0.90, green: 0.90, blue: 0.88))
                        Text(String((c.authorName ?? "?").prefix(1)))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.43))
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.authorName ?? "")
                                .font(.system(size: 12, weight: .medium))
                            if c.byAuthor {
                                Text("作者")
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color(red: 0.92, green: 0.27, blue: 0.29).opacity(0.12))
                                    .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        Text(c.text ?? "")
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if c.likedByAuthor {
                                Text("作者赞过")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(red: 0.82, green: 0.28, blue: 0.25))
                            }
                            if let date = c.postedDate {
                                Text(fmtTime(date)).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            if let likes = c.likes, likes > 0 {
                                Text("赞 \(likes)").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 存档自身的元信息，放底部，不喧宾夺主。
    private func archiveMeta(_ d: ArchiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.bottom, 2)
            HStack(spacing: 8) {
                Text(d.state.label)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("首次归档 \(fmt(d.firstSeenDate))")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let note = d.stateNote, !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private func compactCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000.0) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return "\(n)"
    }

    /// 相对时间：今天显示时分，今年显示 M月d日，跨年带年份。
    private func fmtTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            f.dateFormat = "M月d日 HH:mm"
        } else {
            f.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return f.string(from: date)
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    private func load() async {
        let key = "archive:item:\(itemID)"
        // 先灌缓存：断网/弱网也能秒看上次内容
        if let cached = DataCache.load(key, as: ArchiveDetail.self, maxAge: 30 * 24 * 3600) {
            await MainActor.run { detail = cached }
        }
        do {
            let d = try await APIClient.shared.archiveItem(id: itemID)
            await MainActor.run { detail = d }
            DataCache.save(key, value: d)
        } catch let e as APIError {
            // 有缓存时不弹错误（旧内容照样能看），只在完全没数据时提示
            await MainActor.run { if detail == nil { errorText = e.errorDescription } }
        } catch {
            await MainActor.run { if detail == nil { errorText = error.localizedDescription } }
        }
    }
}

/// 微博九宫格用图：多图正方形填充裁切，单图按原始比例。
private struct WeiboGridImage: View {
    let itemID: Int
    let seq: Int
    let aspect: Double

    @StateObject private var loader = ImageLoader()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = loader.image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ZStack {
                        Color(red: 0.96, green: 0.96, blue: 0.95)
                        if loader.failed {
                            Image(systemName: "photo").foregroundColor(.gray.opacity(0.5))
                        } else {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear { loader.load(itemID: itemID, seq: seq, tier: .detail) }
    }
}

// MARK: - 全屏看图

/// 全屏看图：原图画质 + 双指缩放 + 单击/下滑退出 + 存相册。
///
/// 画质策略（用户反馈「点开显示的不是原图，有点糊」）
/// ------------------------------------------------
/// 旧实现默认铺 thumb=1（长边 900px），只有双击才换原图 ——
/// 在 iPhone 上 900px 铺满 393pt 宽的屏幕，放大后立刻能看出糊。
/// 现在改成「预览 + 原图」双路并发：thumb=1 通常已在九宫格阶段
/// 落进缓存，所以它瞬间可用（避免黑屏等待），原图随后到位即替换。
/// 两条路各自独立取消，不会互相抢占 —— 这一点很重要，
/// ImageLoader 的 task 是单槽的，用同一个实例连发两次会取消前一次。
///
/// 白边（用户反馈「图片四周有一圈白边」）
/// ---------------------------------
/// 根因在 RemoteImage 的卡片外观：`RoundedRectangle(cornerRadius: 8)`
/// 裁角 + 0.5pt 浅灰描边。白底列表里这是必要的分隔，
/// 但黑底全屏下它会变成一圈发亮的白边、还把图片四角啃掉。
/// 这里不走 RemoteImage，直接自绘 Image，从根上不画任何边框。
struct ImageViewer: View {
    let media: [ArchiveMedia]
    let itemID: Int
    @State private var index: Int
    /// 每页已加载到的图片，供「保存」取用。
    /// 用字典按页号存而不是单个状态：TabView 会预载相邻页，
    /// 单个变量会被邻页的图覆盖，保存下来就成了隔壁那张。
    @State private var images: [Int: UIImage] = [:]
    /// 下滑进度 0…1，用于背景淡出
    @State private var dismissProgress: CGFloat = 0
    @State private var saveAlert: SaveAlert?
    @Environment(\.dismiss) private var dismiss

    private struct SaveAlert: Identifiable {
        let id = UUID()
        let title: String
    }

    init(media: [ArchiveMedia], startIndex: Int, itemID: Int) {
        self.media = media
        self.itemID = itemID
        _index = State(initialValue: min(max(0, startIndex), max(0, media.count - 1)))
    }

    var body: some View {
        ZStack {
            // 背景随下滑淡出，松手回弹 —— 这是 iOS 相册的同款观感
            Color.black
                .opacity(1 - 0.55 * min(max(dismissProgress, 0), 1))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.element.id) { i, m in
                    ZoomableImage(itemID: itemID,
                                  media: m,
                                  pageIndex: i,
                                  images: $images,
                                  dismissProgress: $dismissProgress,
                                  onDismiss: { dismiss() })
                        .tag(i)
                }
            }
            // 圆点翻页指示器永久关掉（用户要求：底部翻页控件无需显示）
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            overlay
        }
        .statusBarHidden(true)
        .alert(item: $saveAlert) { a in
            Alert(title: Text(a.title))
        }
    }

    private var overlay: some View {
        VStack {
            ZStack {
                HStack {
                    circleButton("xmark") { dismiss() }
                    Spacer()
                    circleButton("square.and.arrow.down") { save() }
                }
                // 计数器居中，不参与两侧按钮的布局
                if media.count > 1 {
                    Text("\(index + 1) / \(media.count)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private func save() {
        guard let img = images[index] else {
            saveAlert = SaveAlert(title: "图片还没加载完成，稍等一下再保存")
            return
        }
        PhotoSaver.save(img) { result in
            switch result {
            case .success:
                saveAlert = SaveAlert(title: "已保存到相册")
            case .failure(let err):
                let denied = (err as? PhotoSaver.Denied) != nil
                saveAlert = SaveAlert(title: denied
                    ? "没有相册写入权限，请到 设置 › 沃池 › 照片 里打开「添加照片」"
                    : "保存失败：\(err.localizedDescription)")
            }
        }
    }
}

/// 可缩放的单张图。手势分工：
///   · 未缩放 → 纵向拖拽 = 下滑退出（图片跟手、缩小、背景淡出）
///   · 未缩放 → 横向拖动 = 翻页（交给 TabView，这里绝不拦截）
///   · 已缩放 → 拖拽 = 平移图片（UIScrollView 原生接管）
///   · 单击 = 退出，双击 = 定点放大/还原
///
/// 为什么改用 UIScrollView（对应两处用户反馈）：
///   1. 糊 —— 之前用 `scaleEffect` 缩放，SwiftUI 只把「按布局尺寸渲染好的
///      位图」做 GPU 放大，不会按新尺寸重绘，放大即马赛克。哪怕原图已加载
///      （4126px），放大后仍是 900px 底子的糊。UIScrollView 的原生 zoom
///      是重新采样 CGImage 的，放大到几倍都清晰。
///   2. 左右翻页失效 —— 之前为「下滑退出」挂了 DragGesture，它把横向拖动
///      一并吃掉，TabView 就翻不了页。UIScrollView 在 1x 时内容恰好铺满、
///      没有可滚动区域，横向拖动自然交还 TabView。
private struct ZoomableImage: View {
    let itemID: Int
    let media: ArchiveMedia
    let pageIndex: Int
    @Binding var images: [Int: UIImage]
    @Binding var dismissProgress: CGFloat
    var onDismiss: () -> Void

    /// 900px 预览图：九宫格阶段已缓存，进来基本瞬显
    @StateObject private var preview = ImageLoader()
    /// 原图：3–7MB，慢一点，到位后替换预览
    @StateObject private var full = ImageLoader()

    @State private var dragY: CGFloat = 0

    private var displayImage: UIImage? { full.image ?? preview.image }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = displayImage {
                    ZoomableScrollView(
                        image: img,
                        onSingleTap: { onDismiss() },
                        onDismissChanged: { dy in
                            dragY = max(dy, 0)
                            dismissProgress = min(max(dy / 400, 0), 1)
                        },
                        onDismissEnd: { dy, velY in
                            if dy > 120 || velY > 1200 {
                                onDismiss()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    dragY = 0
                                    dismissProgress = 0
                                }
                            }
                        }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    // 下滑时整体缩小下移，配合外层背景淡出
                    .scaleEffect(1 - min(max(dragY, 0) / 900, 0.22))
                    .offset(y: dragY)
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { load() }
        // 预览/原图任一到位就记下，供「保存」用
        .onReceive(preview.$image) { img in
            if let img { images[pageIndex] = img }
        }
        .onReceive(full.$image) { img in
            if let img { images[pageIndex] = img }
        }
    }

    private func load() {
        // 先铺预览（大概率命中缓存），再拉原图。两个独立 loader，互不取消。
        preview.load(itemID: itemID, seq: media.seq, tier: .detail)
        full.load(itemID: itemID, seq: media.seq, tier: .original)
    }
}

/// 布局回调钩子：在 layoutSubviews 里校正 imageView 的 frame。
/// 用子类而不是在 makeUIView 里写死 frame —— 那时 bounds 还是 .zero。
private final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// 基于 UIScrollView 的原生缩放容器。
///
/// 把「缩放 + 平移 + 双击放大」这些复合手势交给 UIKit 里打磨了几十年的
/// UIScrollView，而不是用 SwiftUI 的 MagnificationGesture + DragGesture 拼
/// —— 后者做不到无缝的缩放↔平移切换，也做不到放大后按新尺寸重绘。
private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void
    var onDismissChanged: (CGFloat) -> Void
    var onDismissEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap,
                    onDismissChanged: onDismissChanged,
                    onDismissEnd: onDismissEnd)
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.backgroundColor = .black
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 4.0
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.bouncesZoom = true
        sv.contentInsetAdjustmentBehavior = .never
        sv.decelerationRate = .fast

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.isUserInteractionEnabled = true
        sv.addSubview(iv)

        // 双击：定点放大
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        // 单击：退出。require 双击失败后才触发，否则双击会被误判成单击退出。
        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        sv.addGestureRecognizer(singleTap)

        // 下滑退出：纵向拖拽
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleDismissPan(_:)))
        pan.delegate = context.coordinator
        sv.addGestureRecognizer(pan)

        context.coordinator.scrollView = sv
        context.coordinator.imageView = iv
        context.coordinator.dismissPan = pan
        sv.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.relayout()
        }
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDismissChanged = onDismissChanged
        context.coordinator.onDismissEnd = onDismissEnd
        // 换图（预览 → 原图）：更新 imageView 并复位缩放
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            sv.setZoomScale(1.0, animated: false)
        }
        context.coordinator.relayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var onSingleTap: () -> Void
        var onDismissChanged: (CGFloat) -> Void
        var onDismissEnd: (CGFloat, CGFloat) -> Void

        weak var scrollView: ZoomScrollView?
        weak var imageView: UIImageView?
        weak var dismissPan: UIPanGestureRecognizer?

        init(onSingleTap: @escaping () -> Void,
             onDismissChanged: @escaping (CGFloat) -> Void,
             onDismissEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onSingleTap = onSingleTap
            self.onDismissChanged = onDismissChanged
            self.onDismissEnd = onDismissEnd
        }

        /// 校正 imageView 尺寸并居中。1x 时 imageView 恰好铺满 scroll view，
        /// 此时没有可滚动内容，横向拖动才会交还给 TabView 翻页。
        func relayout() {
            guard let sv = scrollView, let iv = imageView else { return }
            guard sv.bounds.width > 0, sv.bounds.height > 0 else { return }
            if iv.frame.size != sv.bounds.size {
                iv.frame = CGRect(origin: .zero, size: sv.bounds.size)
                sv.contentSize = sv.bounds.size
            }
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
        }

        func centerImage() {
            guard let sv = scrollView, let iv = imageView else { return }
            let ox = max((sv.bounds.width - sv.contentSize.width) / 2, 0)
            let oy = max((sv.bounds.height - sv.contentSize.height) / 2, 0)
            iv.center = CGPoint(x: sv.contentSize.width / 2 + ox,
                                y: sv.contentSize.height / 2 + oy)
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1.0, animated: true)
            } else {
                let p = g.location(in: imageView)
                let side: CGFloat = 120
                sv.zoom(to: CGRect(x: p.x - side / 2, y: p.y - side / 2,
                                   width: side, height: side), animated: true)
            }
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc func handleDismissPan(_ pan: UIPanGestureRecognizer) {
            let t = pan.translation(in: pan.view)
            switch pan.state {
            case .changed:
                onDismissChanged(t.y)
            case .ended:
                onDismissEnd(t.y, pan.velocity(in: pan.view).y)
            case .cancelled, .failed:
                onDismissEnd(t.y, 0)
            default:
                break
            }
        }

        // 只有「未缩放 + 纵向占主导」才让下滑退出手势开始。
        // 横向拖动不拦 → TabView 翻页；已缩放时不拦 → UIScrollView 平移。
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === dismissPan {
                let zoomed = (scrollView?.zoomScale ?? 1) > 1.01
                if zoomed { return false }
                let v = (g as? UIPanGestureRecognizer)?.velocity(in: g.view) ?? .zero
                return abs(v.y) > abs(v.x)
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - 存相册

/// 保存图片到系统相册。
/// 走 PHPhotoLibrary 而不是老的 UIImageWriteToSavedPhotosAlbum：
/// 后者没有结果回调，失败（多半是没权限）时用户只会觉得「点了没反应」。
enum PhotoSaver {
    struct Denied: LocalizedError {
        var errorDescription: String? { "无相册写入权限" }
    }
    struct EncodeFailed: LocalizedError {
        var errorDescription: String? { "图片编码失败" }
    }

    /// 保存到系统相册。
    ///
    /// 为什么不用 `creationRequestForAsset(from: UIImage)`：
    /// 对「网络下载 + 解码」来的大图，Photos 的资产校验经常报
    /// 3302（invalidResource，即「资产资源校验失败」），用户看到的就是
    /// 「保存失败：未能完成操作」。原因是直接把内存里的 UIImage 丢给
    /// Photos，其底层编码/校验对这类来源不稳。
    ///
    /// 可靠路径是系统推荐的做法：先编码成标准 JPEG 落盘（临时文件），
    /// 再 `addResource(with: .photo, fileURL:)` 交给 Photos，由它自己
    /// 从文件读，避开内存位图那套校验。文件扩展名必须正确，否则同样 3302。
    static func save(_ image: UIImage,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(Denied())) }
                return
            }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw_save_\(UUID().uuidString).jpg")
            do {
                // 先 JPEG（有损但兼容性最好），编不出来退回 PNG。
                guard let data = image.jpegData(compressionQuality: 1.0)
                        ?? image.pngData() else {
                    DispatchQueue.main.async { completion(.failure(EncodeFailed())) }
                    return
                }
                try data.write(to: tmp, options: .atomic)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: tmp, options: nil)
            }, completionHandler: { ok, err in
                try? FileManager.default.removeItem(at: tmp)  // 用完即删
                DispatchQueue.main.async {
                    if ok { completion(.success(())) }
                    else { completion(.failure(err ?? Denied())) }
                }
            })
        }
    }
}
