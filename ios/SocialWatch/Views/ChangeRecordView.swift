import SwiftUI

/// 点卡片弹出的变更记录：个人信息 + 变更事件 + 最近发布 + 歌单明细。
struct ChangeRecordView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @Environment(\.presentationMode) private var presentation
    let card: MonitorCard

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        ProxyImage(url: card.avatar, placeholderText: card.name, circular: true)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.system(size: 16, weight: .medium))
                            Text(card.platform).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                }

                if !card.events.isEmpty {
                    Section("变更事件") {
                        ForEach(card.events) { e in
                            eventRow(e)
                        }
                    }
                }

                if !card.recentPosts.isEmpty {
                    Section("最近发布") {
                        ForEach(card.recentPosts) { post in
                            postRow(post)
                        }
                    }
                }

                if !card.playlists.isEmpty {
                    Section("歌单变动") {
                        ForEach(card.playlists) { pl in
                            PlaylistRow(playlist: pl)
                        }
                    }
                }

                if card.events.isEmpty && card.recentPosts.isEmpty && card.playlists.isEmpty {
                    Section {
                        Text("暂无变更记录").font(.system(size: 14)).foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("变更记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func eventRow(_ e: ChangeEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(e.tag)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundColor(e.isAdd ? Color(red: 0.75, green: 0.28, blue: 0.22)
                                     : Color(red: 0.16, green: 0.5, blue: 0.31))
                    .background((e.isAdd ? Color(red: 0.96, green: 0.9, blue: 0.89)
                                 : Color(red: 0.9, green: 0.95, blue: 0.92)))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(timeText(e.detectedDate))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            if !e.detailText.isEmpty {
                Text(e.detailText).font(.system(size: 14))
            }
        }
        .padding(.vertical, 2)
    }

    private func postRow(_ post: RecentPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = post.text, !text.isEmpty {
                Text(TextSanitizer.clean(text)).font(.system(size: 14)).lineLimit(6)
            }
            HStack(spacing: 12) {
                if let l = post.likes, l > 0 {
                    Label("\(l)", systemImage: "heart").font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let c = post.commentsCount, c > 0 {
                    Label("\(c)", systemImage: "bubble.left").font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let r = post.reposts, r > 0 {
                    Label("\(r)", systemImage: "arrow.2.squarepath").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistDetail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProxyImage(url: playlist.cover, placeholderText: playlist.name)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("\(playlist.trackCount) 首 · 增 \(playlist.added.count) / 删 \(playlist.removed.count)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
            }
            if !playlist.events.isEmpty {
                Button { withAnimation { expanded.toggle() } } label: {
                    Text(expanded ? "收起明细" : "展开全部 \(playlist.events.count) 条")
                        .font(.system(size: 12)).foregroundColor(.blue)
                }
                if expanded {
                    ForEach(Array(playlist.events.prefix(40))) { e in
                        HStack {
                            Text(e.tag).font(.system(size: 10)).foregroundColor(.secondary)
                            Text(e.itemName ?? "").font(.system(size: 12))
                            Spacer()
                            Text(timeText(e.detectedDate)).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

struct RunsListView: View {
    @Environment(\.presentationMode) private var presentation
    let runs: [RunRecord]

    var body: some View {
        NavigationView {
            List(runs) { run in
                RunRow(run: run).padding(.vertical, 4)
            }
            .navigationTitle("巡检记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
