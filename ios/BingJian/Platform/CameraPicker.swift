import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> CameraPickerCoordinator {
        CameraPickerCoordinator(onImage: onImage, onDismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

final class CameraPickerCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onImage: (Data) -> Void
    private let onDismiss: () -> Void

    init(onImage: @escaping (Data) -> Void, onDismiss: @escaping () -> Void) {
        self.onImage = onImage
        self.onDismiss = onDismiss
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { onImage(data) }
        onDismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDismiss() }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
