import SwiftUI
import Vision

struct ServerPairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pairing: ServerPairing?
    @State private var camera = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("部署者提供的配对信息") {
                TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 140)
                Button("解析并核对") {
                    do { pairing = try ServerPairing.parse(text) }
                    catch { self.error = error.localizedDescription }
                }
                Button("扫描配对二维码") { camera = true }
            }
            if let pairing {
                Section("请与部署者核对") {
                    LabeledContent("后台地址", value: pairing.url)
                    Text("服务身份 " + pairing.instanceId).font(.caption).textSelection(.enabled)
                    Text("CA 指纹 SHA-256").font(.caption)
                    Text(pairing.caSha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("先在系统安装并信任部署者的根证书，再确认此地址、服务身份和证书指纹。").font(.caption).foregroundStyle(.secondary)
                    Button("已核对，验证连接并保存") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                try await pairing.verify()
                                try await model.saveServerAddress(pairing.url)
                                UserDefaults.standard.set(pairing.instanceId, forKey: "server_expected_instance:" + model.serverURL)
                                model.notice = "服务身份与证书指纹已验证并保存"
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy)
                    if busy { ProgressView() }
                }
            }
        }
        .navigationTitle("核验服务器")
        .onChange(of: text) { _, _ in pairing = nil }
        .sheet(isPresented: $camera) {
            CameraPicker { data in
                Task {
                    do {
                        let value = try await Task.detached(priority: .userInitiated) {
                            let request = VNDetectBarcodesRequest()
                            request.symbologies = [.qr]
                            try VNImageRequestHandler(data: data).perform([request])
                            return request.results?.first?.payloadStringValue
                        }.value
                        guard let value else { throw APIError(code: "QR_NOT_FOUND", message: "没有识别到配对二维码") }
                        text = value
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .alert("服务器核验未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
