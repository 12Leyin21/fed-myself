import SwiftUI

/// 按名字搜（2026-09-27：记不住全名、手边没有条码也能自己录——搜「梦龙」就出来梦龙的各个产品）。
/// 数据是 Open Food Facts（服务器转）。挑中一样 → 回到记一餐的页面，跟扫码一样填克数就记。

struct FoodSearchLookup: Decodable {
    let source: String?
    let products: [BarcodeProduct]
}

struct FoodSearchSheet: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    /// 搜一个词；nil = 没连上
    let search: (String) async -> [BarcodeProduct]?
    let onPick: (BarcodeProduct) -> Void

    static var demo: Bool { ProcessInfo.processInfo.arguments.contains("-foodSearchDemo") }

    @State private var query = FoodSearchSheet.demo ? "梦龙" : ""
    @State private var results: [BarcodeProduct] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var failed = false
    @State private var seq = 0          // 每查一次 +1；回来的结果不是最新那次的就不要
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜吃的，比如 梦龙、Magnum", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await run(query) } }
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(Fonts.body(16))
                    .padding(14)
                    .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))

                    if searching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("在查…").font(Fonts.body(13)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    ForEach(Array(results.enumerated()), id: \.offset) { _, p in
                        Button {
                            onPick(p)
                            dismiss()
                        } label: {
                            row(p)
                        }
                        .buttonStyle(.plain)
                    }

                    if !searching && !searched.isEmpty && results.isEmpty {
                        Text(failed
                             ? "没连上，等一下再试。"
                             : "没搜到「\(searched)」。中文收录的少，试试英文名或牌子（比如 Magnum）；实在没有就回去直接写，\(FoodLogConfig.aiName)来估。")
                            .font(Fonts.body(13)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    Text("数据来自 Open Food Facts（大家一起填的开放数据库）。挑中一样，填吃了多少克就能记。")
                        .font(Fonts.body(11.5)).foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .containerBackground(.clear, for: .navigation)
            .navigationTitle("搜名字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            // 边打边搜：停手 0.6 秒再查，打字过程中不一直打扰服务器
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else {
                    seq += 1            // 作废还在路上的那次
                    searching = false
                    if q.isEmpty { results = []; searched = "" }
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await run(q)
            }
            .onAppear { if !Self.demo { focused = true } }
        }
        .tint(theme.accent)
    }

    private func row(_ p: BarcodeProduct) -> some View {
        let sub = [p.brand, p.serving.isEmpty ? "" : "一份 \(p.serving)"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(Fonts.body(15, .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !sub.isEmpty {
                    Text(sub).font(Fonts.body(12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Int(p.kcal_100g.rounded()))").font(Fonts.body(17, .semibold))
                Text("kcal/100g").font(Fonts.body(10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private func run(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != searched || failed else { return }
        seq += 1
        let mine = seq
        searching = true
        failed = false
        let r = await search(q)
        // 查的这一会儿她又改了字：旧结果不要了，等新的那次
        guard mine == seq else { return }
        searching = false
        searched = q
        results = r ?? []
        failed = r == nil
    }
}
