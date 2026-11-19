import Foundation

extension AppModel {
    /// 调用方在本机保存/启动/同步成功后触发；备份失败不会回滚已经保存的业务数据。
    func scheduleLocalBackup() {
        guard let store = try? requireStore() else { return }
        Task { await LocalBackupService.shared.schedule(store: store) }
    }
}
