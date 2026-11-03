// Choices that follow the person to every device: the accent colour and the code size. They live in iCloud key-value
// storage and are mirrored into UserDefaults, where the views read them with @AppStorage. With iCloud off they simply
// stay on this device. Siri sharing and Private Cloud Compute are about this device, so they stay in UserDefaults only.
import Foundation

@MainActor
enum CloudSettings {
    static let keys = ["accent", "editorFontSize"]

    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        cloud.synchronize()
        // Whatever iCloud already has wins on launch; a fresh device takes the person's choices.
        for key in keys {
            if let value = cloud.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? keys
            MainActor.assumeIsolated {
                for key in changed where keys.contains(key) {
                    UserDefaults.standard.set(NSUbiquitousKeyValueStore.default.object(forKey: key), forKey: key)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for key in keys {
                    let local = UserDefaults.standard.object(forKey: key)
                    let remote = NSUbiquitousKeyValueStore.default.object(forKey: key)
                    if let local, !isEqual(local, remote) { NSUbiquitousKeyValueStore.default.set(local, forKey: key) }
                }
            }
        })
    }

    private static func isEqual(_ a: Any, _ b: Any?) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }
}
