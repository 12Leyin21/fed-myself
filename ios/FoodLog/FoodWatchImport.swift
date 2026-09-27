import Foundation
import HealthKit

/// Apple Watch 锻炼 → 饮食本的运动。
/// 手表上结束一次锻炼，它存进「健康」；打开饮食本时读昨天到现在的锻炼，每次一条：
/// 项目名（力量训练 / 跑步…）、时长、手表测的活动消耗——准数，不用估。
/// 带着那次锻炼的编号（ext_id），同一次不记两遍；删掉的服务器记着，也不会再导回来。
enum FoodWatchImport {
    /// 设置页的开关（默认开）
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "foodWatchImport") as? Bool ?? true
    }

    private static let health = HKHealthStore()
    private static var lastRun: Date?

    /// 读锻炼、导进去；返回新记了几条。一分钟内只跑一次，没权限 / 没数据就安静地什么都不做。
    @MainActor
    static func run(into store: FoodStore) async -> Int {
        guard enabled, HKHealthStore.isHealthDataAvailable() else { return 0 }
        if let last = lastRun, Date().timeIntervalSince(last) < 60 { return 0 }
        lastRun = Date()
        let energy = HKQuantityType(.activeEnergyBurned)
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), energy]
        guard (try? await health.requestAuthorization(toShare: [], read: types)) != nil else { return 0 }

        let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 50,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            health.execute(q)
        }
        var added = 0
        for w in workouts {
            let minutes = Int((w.duration / 60).rounded())
            guard minutes >= 1 else { continue }
            let kcal = w.statistics(for: energy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
            if await store.addImported(date: FoodStore.dayKey(w.endDate), text: name(w.workoutActivityType),
                                       detail: "\(minutes) 分钟", kcal: kcal.map { $0.rounded() },
                                       extID: "hk-\(w.uuid.uuidString)") {
                added += 1
            }
        }
        return added
    }

    static func name(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .yoga: return "瑜伽"
        case .pilates: return "普拉提"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "椭圆机"
        case .stairClimbing, .stairs, .stepTraining: return "爬楼梯"
        case .coreTraining: return "核心训练"
        case .flexibility: return "拉伸"
        case .cooldown: return "放松"
        case .hiking: return "徒步"
        case .rowing: return "划船"
        case .jumpRope: return "跳绳"
        case .mixedCardio: return "混合有氧"
        case .dance, .socialDance, .cardioDance: return "跳舞"
        case .barre: return "芭蕾把杆"
        case .boxing, .kickboxing: return "拳击"
        case .tennis: return "网球"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .climbing: return "攀岩"
        case .mindAndBody: return "身心训练"
        default: return "锻炼"
        }
    }
}
