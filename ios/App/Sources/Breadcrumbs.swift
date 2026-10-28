import Foundation
import UIKit
import os

/// What the app was doing, kept where a sudden end (iPadOS stopping it for memory) can't erase it:
/// the next launch tells what was going on and how much memory was left then.
enum Breadcrumbs {
    private static let key = "lastCrumb"
    private static let alive = "alive"

    /// The app is in front (set at launch and when it comes back); a clean leave clears it.
    static func launched() -> String? {
        let d = UserDefaults.standard
        var report: String?
        if d.bool(forKey: alive), let c = d.string(forKey: key) {
            report = c
        }
        d.set(true, forKey: alive)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(false, forKey: alive)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: alive)
        }
        return report
    }

    /// Before something heavy: what, and the memory left.
    static func mark(_ what: String) {
        let free = os_proc_available_memory() / 1_048_576
        UserDefaults.standard.set("\(what) · memoria libera \(free) MB", forKey: key)
    }
}
