import UIKit

/// Returns only to the PID-verified source app; never guesses an installed app.
/// App URL open acceptance does not itself prove same-chat restoration.
/// Flow reference: getdictus/dictus-ios @ 0fd7badf47e1f98f3e3757dc84a2b1d4720d9ed8.
@MainActor
enum MobileReturnNavigator {
    // Small, explicit resume-scheme set. No caller-supplied URLs or arbitrary URL actions.
    private static let resumeURLs = [
        "com.tencent.xin": "weixin://",
        "net.whatsapp.WhatsApp": "whatsapp-consumer://",
        "ph.telegra.Telegraph": "tg://",
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.mobilemail": "message://",
        "com.tinyspeck.chatlyio": "slack://open"
    ]
    static func returnToOrigin(bundleID: String?, completion: @escaping (Bool) -> Void) {
        UserDefaults.standard.set(bundleID, forKey: "lastNavigationSource")
        UserDefaults.standard.removeObject(forKey: "lastNavigationAccepted")
        guard let bundleID, let raw = resumeURLs[bundleID], let url = URL(string: raw) else {
            UserDefaults.standard.set(false, forKey: "lastNavigationAccepted")
            completion(false); return
        }
        UIApplication.shared.open(url, options: [:]) { accepted in
            UserDefaults.standard.set(accepted, forKey: "lastNavigationAccepted")
            completion(accepted)
        }
    }
}
