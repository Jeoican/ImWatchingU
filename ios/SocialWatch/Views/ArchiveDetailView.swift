import SwiftUI

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
        .task { await load() }
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

/// 三档渐进 + 双指缩放 + 手势翻页。
///
/// 三档顺序（这是 web 端验证过的策略）
/// ---------------------------------
/// 先铺 thumb=1（900px, ~105KB，几乎瞬到）→ 后台静默换原图。
/// 一上来就拉 4MB 原图会黑屏等 0.3–1 秒，体验很差。
/// 只有用户双击 1:1 时才必须原图 —— 那时他已明确要看细节。
struct ImageViewer: View {
    let media: [ArchiveMedia]
    let itemID: Int
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(media: [ArchiveMedia], startIndex: Int, itemID: Int) {
        self.media = media
        self.itemID = itemID
        _index = State(initialValue: min(max(0, startIndex), max(0, media.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.element.id) { i, m in
                    ZoomableImage(itemID: itemID, media: m)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            overlay
        }
        .statusBarHidden(true)
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                Spacer()
                Text("\(index + 1) / \(media.count)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            if media.count > 1 {
                HStack(spacing: 32) {
                    Button { if index > 0 { index -= 1 } } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.35 : 1)

                    Button { if index < media.count - 1 { index += 1 } } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .disabled(index == media.count - 1)
                    .opacity(index == media.count - 1 ? 0.35 : 1)
                }
                .padding(.bottom, 28)
            }
        }
    }
}

/// 可缩放的单张图。
struct ZoomableImage: View {
    let itemID: Int
    let media: ArchiveMedia

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isActual = false

    var body: some View {
        GeometryReader { geo in
            RemoteImage(itemID: itemID, seq: media.seq,
                        tier: isActual ? .original : .detail,
                        aspectRatio: media.aspectRatio)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .onTapGesture(count: 2) { toggleActual() }
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                scale = min(max(lastScale * v, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 {
                    scale = 1; lastScale = 1
                    offset = .zero; lastOffset = .zero
                }
            }
    }

    private func toggleActual() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isActual {
                isActual = false
                scale = 1; lastScale = 1
                offset = .zero; lastOffset = .zero
            } else {
                isActual = true
                scale = 1.6; lastScale = 1.6
            }
        }
    }
}
