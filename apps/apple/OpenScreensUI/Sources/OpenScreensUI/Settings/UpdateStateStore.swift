import Foundation

/// Remembers which rolling snapshot is actually installed. The label is
/// committed only once the app executable is newer than the moment the
/// installer was opened, so cancelling the installer does not hide the update.
enum UpdateStateStore {
    private static let installedKey = "openscreens.update.installedSnapshotV2"
    private static let pendingKey = "openscreens.update.pendingSnapshot"
    private static let pendingAtKey = "openscreens.update.pendingSnapshotAt"

    static func installedSnapshot() -> String? {
        commitPendingIfInstalled()
        return UserDefaults.standard.string(forKey: installedKey)
    }

    static func markInstallStarted(_ label: String) {
        UserDefaults.standard.set(label, forKey: pendingKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: pendingAtKey)
    }

    private static func commitPendingIfInstalled() {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: pendingKey) else { return }
        let since = defaults.double(forKey: pendingAtKey)
        guard since > 0 else {
            defaults.removeObject(forKey: pendingKey)
            defaults.removeObject(forKey: pendingAtKey)
            return
        }
        guard let executable = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: executable.path
              ),
              let modified = attributes[.modificationDate] as? Date,
              modified.timeIntervalSince1970 >= since
        else { return }

        defaults.set(pending, forKey: installedKey)
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: pendingAtKey)
    }
}
