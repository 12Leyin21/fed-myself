import SwiftUI
import VisionKit

/// 扫条形码 / 拍营养表：条码查 Open Food Facts（这一样东西本身的数），
/// 查不到就拍背面的营养成分表给 AI 读。

struct BarcodeProduct: Decodable, Equatable {
    let name: String
    let brand: String
    let kcal_100g: Double
    let protein_100g: Double?
    let carbs_100g: Double?
    let fat_100g: Double?
    let serving: String
    let kcal_serving: Double?

    /// 「1 portion (101 g)」「30g」→ 101 / 30；认不出来就 nil
    var servingGrams: Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:g|ml)\b"#
        guard let r = serving.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = serving[r].filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}

struct BarcodeLookup: Decodable {
    let found: Bool
    let product: BarcodeProduct?
    let code: String
}

/// 相机取景扫条码，扫到第一个就回调关掉
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let b) = item, let code = b.payloadStringValue, !code.isEmpty {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(code)
                    return
                }
            }
        }
    }
}

/// 扫到了：这样东西每 100g 多少，填吃了多少克，算出来直接记
struct BarcodeResultCard: View {
    @EnvironmentObject var theme: AppTheme
    let product: BarcodeProduct
    @Binding var grams: Double?
    var icon = "barcode.viewfinder"     // 扫码来的是条码，搜名字来的是放大镜
    let onSave: () -> Void
    let onCancel: () -> Void

    private func scaled(_ per100: Double?) -> String {
        guard let per100, let g = grams else { return "–" }
        return String(format: "%.0f", per100 * g / 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name).font(Fonts.body(15, .semibold))
                    if !product.brand.isEmpty {
                        Text(product.brand).font(Fonts.body(12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { onCancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            Text("每 100g：\(Int(product.kcal_100g.rounded())) kcal · 蛋白 \(fmt(product.protein_100g)) · 碳水 \(fmt(product.carbs_100g)) · 脂肪 \(fmt(product.fat_100g))")
                .font(Fonts.body(12.5)).foregroundStyle(.secondary)
            HStack {
                Text("吃了")
                TextField("克数", value: $grams, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                Text("g")
                if let sg = product.servingGrams {
                    Button("一份 \(Int(sg))g") { grams = sg }
                        .font(Fonts.body(12.5)).buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Text("\(scaled(product.kcal_100g)) kcal").font(Fonts.body(15, .semibold))
            }
            Button {
                onSave()
            } label: {
                Text("记下这一样").font(Fonts.body(15, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled((grams ?? 0) <= 0)
        }
        .padding(14)
        .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%gg", $0) } ?? "?" }
}
