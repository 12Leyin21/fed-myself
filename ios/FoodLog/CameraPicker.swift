import SwiftUI
import UIKit

/// 拍照。SwiftUI 到今天也没给相机一个原生 picker（PhotosPicker 只管相册），
/// 所以这里包一层 UIImagePickerController。
///
/// 模拟器上没有相机，`isSourceTypeAvailable` 会是 false——那种情况下调用方
/// 直接不显示这一项，免得点了弹一个黑屏。
struct CameraPicker: UIViewControllerRepresentable {
    /// 拍完给出压缩好的 JPEG
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // 和相册那条路走同一套压缩，免得一张原图 12MB 传上去
            if let image = info[.originalImage] as? UIImage,
               let jpeg = image.resizedIfNeeded(maxSide: 1800).jpegData(compressionQuality: 0.8) {
                onCapture(jpeg)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
