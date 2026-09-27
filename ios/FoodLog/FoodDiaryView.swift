import SwiftUI

/// 饮食记录：Library 顶上「饮食」进来。
/// 列表页 Food Diary（每天一张卡）→ 某天 Today's Meal（只读，排好版）→ 右上 ✏️ 进编辑页（FoodEditView）。
/// 风格：毛玻璃卡 + 衬线标题 + 主题色。
struct FoodDiaryView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = FoodStore()
    @State private var query = ""
    // 截图用：-foodDay / -foodEdit 直接推到今天那页
    @State private var path: [FoodRoute] = {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("-foodEdit") ? [.edit(FoodStore.today())] : (a.contains("-foodDay") ? [.day(FoodStore.today())] : [])
    }()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        FoodHeader(title: "Food Diary", back: { dismiss() }) {
                            HStack(spacing: 18) {
                                Button { showSettings = true } label: {
                                    Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold))
                                }
                                Button { path.append(.edit(FoodStore.today())) } label: {
                                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                                }
                            }
                        }
                        searchField
                        if !store.days.contains(where: { $0.date == FoodStore.today() }) && query.isEmpty {
                            emptyToday
                        }
                        ForEach(store.days) { row in
                            Button { path.append(.day(row.date)) } label: { dayRow(row) }
                                .buttonStyle(.plain)
                        }
                        if let e = store.error {
                            Text(e).font(.system(size: 12.5)).foregroundStyle(AppTheme.inkFaint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FoodRoute.self) { route in
                switch route {
                case .day(let date): FoodDayView(store: store, date: date, path: $path)
                case .edit(let date): FoodEditView(store: store, date: date)
                }
            }
        }
        .task { await store.loadDays(); await store.syncWatch() }
        .onChange(of: path) { _, p in if p.isEmpty { Task { await store.loadDays(query: query) } } }
        .sheet(isPresented: $showSettings) {
            FoodSettingsView(store: store).environmentObject(theme)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.inkFaint)
            TextField("按日期或吃的东西找…", text: $query)
                .font(Fonts.body(14))
                .submitLabel(.search)
                .onSubmit { Task { await store.loadDays(query: query) } }
            if !query.isEmpty {
                Button { query = ""; Task { await store.loadDays() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.inkFaint)
                }
            }
        }
        .padding(.horizontal, 14).frame(height: 40)
        .glassEffect(.clear, in: Capsule())
    }

    private var emptyToday: some View {
        Button { path.append(.edit(FoodStore.today())) } label: {
            FoodCard(padding: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FoodStore.enLabel(FoodStore.today())).font(Fonts.serif(16, .semibold)).foregroundStyle(AppTheme.ink)
                        Text("今天还没记 · 点这里开始，或者直接跟\(FoodLogConfig.aiName)说吃了什么")
                            .font(Fonts.body(13)).foregroundStyle(AppTheme.inkFaint)
                    }
                    Spacer()
                    Image(systemName: "plus.circle").font(.system(size: 22)).foregroundStyle(theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func dayRow(_ row: FoodDayRow) -> some View {
        FoodCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(FoodStore.enLabel(row.date)).font(Fonts.serif(16, .semibold)).foregroundStyle(AppTheme.ink)
                    HStack(spacing: 6) {
                        Text("\(row.kcal) kcal").font(Fonts.body(13)).foregroundStyle(AppTheme.inkFaint)
                        if row.pending > 0 {
                            Text("· \(row.pending) 条\(FoodLogConfig.aiName)在估").font(Fonts.body(12)).foregroundStyle(theme.accent)
                        }
                    }
                    Text(row.blurb.isEmpty ? "只记了运动" : row.blurb)
                        .font(Fonts.body(13.5)).foregroundStyle(AppTheme.inkDim)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if !row.photo.isEmpty {
                    AuthImageView(urlPath: row.photo)
                        .frame(width: 86, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

enum FoodRoute: Hashable {
    case day(String)
    case edit(String)
}

/// 房间统一的顶栏：左返回、中间标题、右边自定。
/// 标题和按钮垫液态玻璃（跟底下的毛玻璃卡分开）；标题只留英文，
/// 大字是标题（Today's Meal），小字是日期（Fri 25 Sep）。
struct FoodHeader<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(title).font(Fonts.serifItalic(21)).foregroundStyle(AppTheme.ink)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Fonts.body(12, .medium)).tracking(0.6).foregroundStyle(AppTheme.inkFaint)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, subtitle.isEmpty ? 9 : 6)
            .glassEffect(.regular, in: Capsule())
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.inkDim)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                Spacer()
                trailing
                    .foregroundStyle(AppTheme.inkDim)
                    .padding(.horizontal, 13)
                    .frame(height: 40)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }
}

/// 饮食页的卡：无颜色、几乎透明的磨砂玻璃 + 一圈细白边
struct FoodCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(0.72)
                    shape.fill(.white.opacity(0.06))
                    shape.strokeBorder(.white.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

/// 进度条：往满了走。到了目标就满格 + 勾，超了也只是满着（没有红色，不评价吃多吃少）
struct FoodBar: View {
    @EnvironmentObject var theme: AppTheme
    let label: String
    let value: Int
    let target: Int
    var unit: String = "g"

    var body: some View {
        let ratio = target > 0 ? min(1, Double(value) / Double(target)) : 0
        HStack(spacing: 10) {
            Text(label).font(Fonts.body(13.5)).foregroundStyle(AppTheme.ink).frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.45))
                    Capsule().fill(theme.accent.opacity(0.75)).frame(width: max(6, geo.size.width * ratio))
                }
            }
            .frame(height: 9)
            HStack(spacing: 3) {
                Text("\(String(value)) / \(String(target)) \(unit)").font(.system(size: 12.5).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(AppTheme.inkDim)
                if ratio >= 1 {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.accent)
                }
            }
            .frame(width: 124, alignment: .trailing)
        }
    }
}

/// 某一天排好版的样子（Today's Meal）：三餐 + 加餐 + 运动消耗。
struct FoodDayView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FoodStore
    let date: String
    @Binding var path: [FoodRoute]

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 12) {
                    FoodHeader(title: date == FoodStore.today() ? "Today's Meal" : "The Day's Meal",
                               subtitle: FoodStore.enLabel(date), back: { dismiss() }) {
                        Button { path.append(.edit(date)) } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    if let day = store.day, day.date == date {
                        diningCard(day)
                        totalCard(day)
                        exerciseCard(day)
                        photos(day)
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: date) { await store.loadDay(date); await store.syncWatch() }
        .task(id: store.day?.summary.pending ?? 0) {
            // 有待估的就隔一会儿再拉一次，AI 估好数自己长出来
            guard (store.day?.summary.pending ?? 0) > 0 else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await store.loadDay(date)
        }
    }

    private func sectionTitle(_ en: String, _ zh: String) -> some View {
        Text("\(en)  ·  \(zh)")
            .font(.system(size: 11.5, weight: .medium)).tracking(3)
            .foregroundStyle(AppTheme.inkFaint)
            .frame(maxWidth: .infinity)
    }

    private func diningCard(_ day: FoodDay) -> some View {
        FoodCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("DINING", "餐食")
                ForEach(FoodMeal.meals) { meal in
                    let items = day.entries(meal)
                    if !items.isEmpty { mealBlock(meal, items) }
                }
                if FoodMeal.meals.allSatisfy({ day.entries($0).isEmpty }) {
                    Text("这天还没记吃的").font(Fonts.body(13.5)).foregroundStyle(AppTheme.inkFaint)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func mealBlock(_ meal: FoodMeal, _ items: [FoodEntry]) -> some View {
        let known = items.filter { !$0.pending }
        let kcal = Int(known.reduce(0) { $0 + ($1.kcal ?? 0) }.rounded())
        let p = Int(known.reduce(0) { $0 + ($1.protein ?? 0) }.rounded())
        let c = Int(known.reduce(0) { $0 + ($1.carbs ?? 0) }.rounded())
        let f = Int(known.reduce(0) { $0 + ($1.fat ?? 0) }.rounded())
        let waiting = items.contains { $0.pending }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(meal.rawValue).font(Fonts.serif(16, .semibold)).foregroundStyle(AppTheme.ink)
                // 一样一行：名字，底下灰一点的小字是份量和里面有什么
                ForEach(items) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.text).font(Fonts.body(14)).foregroundStyle(AppTheme.inkDim)
                        if !e.subline.isEmpty {
                            Text(e.subline).font(Fonts.body(11.5)).foregroundStyle(AppTheme.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if waiting {
                    Text("有 \(items.filter(\.pending).count) 样\(FoodLogConfig.aiName)在估…").font(Fonts.body(12)).foregroundStyle(theme.accent)
                }
            }
            Spacer(minLength: 6)
            if known.isEmpty {
                Text("估算中").font(Fonts.body(13)).foregroundStyle(theme.accent)
            } else {
            VStack(alignment: .trailing, spacing: 1) {
                (Text("\(kcal)").font(.system(size: 16, weight: .semibold).monospacedDigit())
                 + Text(" kcal").font(.system(size: 11)))
                    .foregroundStyle(AppTheme.ink)
                Group {
                    Text("P \(p) g"); Text("C \(c) g"); Text("F \(f) g")
                }
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(AppTheme.inkFaint)
            }
            }
        }
    }

    private func totalCard(_ day: FoodDay) -> some View {
        let s = day.summary, t = day.targets
        return FoodCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(s.kcal) kcal").font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Text("P \(s.protein)g · C \(s.carbs)g · F \(s.fat)g")
                        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(AppTheme.inkFaint)
                }
                Text("今日营养进度").font(Fonts.body(13)).foregroundStyle(AppTheme.inkFaint)
                FoodBar(label: "总热量", value: s.kcal, target: t.kcal, unit: "kcal")
                FoodBar(label: "蛋白质", value: s.protein, target: t.protein)
                FoodBar(label: "碳水", value: s.carbs, target: t.carbs)
                FoodBar(label: "脂肪", value: s.fat, target: t.fat)
            }
        }
    }

    private func exerciseCard(_ day: FoodDay) -> some View {
        let items = day.entries(.exercise)
        let s = day.summary
        return FoodCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("EXERCISE", "运动消耗")
                if items.isEmpty {
                    Text("这天没记运动").font(Fonts.body(13.5)).foregroundStyle(AppTheme.inkFaint)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(items) { e in
                        HStack {
                            Image(systemName: "figure.run").foregroundStyle(theme.accent)
                            Text(e.text + (e.detail.map { $0.isEmpty ? "" : " · \($0)" } ?? "")
                                 + (e.source == "watch" ? " ⌚️" : ""))
                                .font(Fonts.body(14)).foregroundStyle(AppTheme.ink)
                            Spacer()
                            Text(e.pending ? "\(FoodLogConfig.aiName)在估…" : "−\(Int((e.kcal ?? 0).rounded())) kcal")
                                .font(.system(size: 13.5).monospacedDigit())
                                .foregroundStyle(e.pending ? theme.accent : AppTheme.inkDim)
                        }
                    }
                }
                // 运动之后的净摄入对着目标（运动从吃进去的里扣，目标不变）
                FoodBar(label: "运动后", value: max(0, s.net), target: day.targets.kcal, unit: "kcal")
            }
        }
    }

    @ViewBuilder
    private func photos(_ day: FoodDay) -> some View {
        let shots = day.entries.map(\.photo).filter { !$0.isEmpty }
        if !shots.isEmpty {
            FoodCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("PHOTO", "照片")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shots, id: \.self) { url in
                                AuthImageView(urlPath: url)
                                    .frame(width: 150, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    // 封面那张右上角一颗星；长按换封面
                                    .overlay(alignment: .topTrailing) {
                                        if shots.count > 1 && url == (day.cover ?? shots.first) {
                                            Image(systemName: "star.fill").font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white).padding(6)
                                                .background(Circle().fill(theme.accent.opacity(0.85))).padding(6)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button { Task { await store.setCover(date: day.date, url: url) } } label: {
                                            Label("设为这天的封面", systemImage: "star")
                                        }
                                    }
                            }
                        }
                    }
                    if shots.count > 1 {
                        Text("长按一张设为列表页的封面").font(Fonts.body(11.5)).foregroundStyle(AppTheme.inkFaint)
                    }
                }
            }
        }
    }
}

/// 设置：直接填每日目标，或者填身体数据让它算（Mifflin-St Jeor × 活动量）
struct FoodSettingsView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FoodStore
    @State private var draft: FoodSettings?
    @AppStorage("foodWatchImport") private var watchImport = true
    @AppStorage("foodLogAIName") private var aiName = ""

    private static let activities: [(String, String)] = [
        ("sedentary", "基本坐着"), ("light", "每周轻运动 1~3 次"), ("moderate", "每周认真运动 3~5 次")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("从 Apple Watch 导入锻炼", isOn: $watchImport)
                } footer: {
                    Text("手表上结束的锻炼会自动记进运动：项目、时长和手表测的消耗。删掉的不会再导回来。")
                }
                Section {
                    TextField("AI", text: $aiName)
                } header: {
                    Text("你的 AI 叫什么")
                } footer: {
                    Text("页面上「在估」「记的」前面显示这个名字，不填就是 AI。")
                }
                if let binding = Binding($draft) {
                    Section {
                        Picker("目标怎么定", selection: binding.mode) {
                            Text("按身体数据算").tag("body")
                            Text("自己填").tag("manual")
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("身体数据") {
                        number("身高", binding.height_cm, "cm")
                        number("体重", binding.weight_kg, "kg")
                        number("年龄", binding.age, "岁")
                        Picker("活动量", selection: binding.activity) {
                            ForEach(Self.activities, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    if binding.wrappedValue.mode == "manual" {
                        Section("每日目标") {
                            number("每日热量", binding.kcal, "kcal")
                            number("蛋白质", binding.protein, "g")
                        }
                    }
                    if let t = store.targets {
                        Section {
                            row("基础代谢", "\(t.bmr) kcal")
                            row("每日消耗", "\(t.tdee) kcal")
                            row("每日目标", "\(t.kcal) kcal · 蛋白 \(t.protein) g")
                        } footer: {
                            Text("目标是保存之后按上面的数算的。运动消耗会从当天吃进去的里面扣，目标本身不变。")
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("饮食设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let d = draft else { return }
                        Task { await store.saveSettings(d) }
                    }
                }
            }
        }
        .tint(theme.accent)
        .task {
            await store.loadSettings()
            draft = store.settings
        }
    }

    private func number(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}
