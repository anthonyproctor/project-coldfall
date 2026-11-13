import AppKit
import UserNotifications
import ColdfallCore

/// Telling you a desk needs you when you aren't looking. When to (see
/// NotifyRule) is decided in the core; this only delivers.
///
/// A banner when Coldfall is in the background, with the system sound;
/// clicking it brings Coldfall forward on that desk. A sound alone when
/// Coldfall is in front, since the rail already shows which desk it was.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Go to this desk: a banner was clicked.
    var onOpen: ((String) -> Void)?
    private var asked = false
    private var allowed = false

    /// Only from a real app bundle. A bare binary (a test copy, a snapshot)
    /// has no identity to post with, and the notification centre crashes.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            DispatchQueue.main.async {
                self?.allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                self?.asked = s.authorizationStatus != .notDetermined
            }
        }
    }

    func deliver(_ alert: NotifyRule.Alert, desk: String, activity: DeskActivity, reason: String? = nil) {
        switch alert {
        case .silent: return
        case .sound: NSSound(named: "Glass")?.play()
        case .banner: post(desk: desk, activity: activity, reason: reason)
        }
    }

    private func post(desk: String, activity: DeskActivity, reason: String?) {
        guard available else { NSSound(named: "Glass")?.play(); return }
        let send = { [weak self] in
            let t = NotifyRule.text(desk: desk, activity, reason: reason)
            let c = UNMutableNotificationContent()
            c.title = t.title
            c.body = t.body
            c.sound = .default
            c.userInfo = ["desk": desk]
            // One per desk: a newer word from the same desk replaces the old.
            let r = UNNotificationRequest(identifier: "desk." + desk, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(r)
            _ = self
        }
        if allowed { send(); return }
        guard !asked else { NSSound(named: "Glass")?.play(); return }
        // First time: ask, then send if allowed.
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.allowed = ok
                if ok { send() } else { NSSound(named: "Glass")?.play() }
            }
        }
    }

    /// Clear a desk's banner once you've gone to it.
    func clear(desk: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["desk." + desk])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let d = r.notification.request.content.userInfo["desk"] as? String {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.onOpen?(d)
            }
        }
        done()
    }

    /// Coldfall came forward between the post and the delivery: show it anyway.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
