/*
Adapted from getdictus/dictus-ios @ 0fd7badf47e1f98f3e3757dc84a2b1d4720d9ed8.
Personal development build: uses private UIKit SPI, not a public API guarantee.

MIT License

Copyright (c) 2026 PIVI Solutions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import UIKit
import ObjectiveC
import OSLog

/// Adapted from upstream HostAppResolver + HostPidTable. Private SPI is optional:
/// a missing runtime hop or nonmatching PID returns nil, never a guessed host.
@MainActor
enum MobileHostAppResolver {
    private static let logger = Logger(subsystem: "com.peter.totype.ios.keyboard", category: "HostResolver")
    // Entries live for ONE keyboard appearance. No persisted or prior-host fallback.
    private static var currentAppearance: [Int: String] = [:]
    private static var lastDiagnostic = ""
    private static var diagnosticCount = 0

    /// Call exactly once in viewWillAppear, not at every mic tap.
    static func prepare() {
        currentAppearance.removeAll(keepingCapacity: true)
        diagnosticCount = 0
        lastDiagnostic = ""
        let activation = MobileHostArbiterActivation.activate()
        guard let client = sharedClient() else { note("prepare:no-client;activation=" + activation); return }
        if read("connection", from: client) == nil {
            let selector = NSSelectorFromString("startConnection")
            guard client.responds(to: selector) else { note("prepare:no-start-selector"); return }
            _ = client.perform(selector)
        }
        harvest(client)
        note("prepare:activation=" + activation + ";load=" + MobileHostArbiterActivation.loadTimeOutcome())
    }

    /// Call at viewDidAppear and at the mic tap. Only the tap result drives return.
    static func sourceBundleID(controller: UIInputViewController) -> String? {
        guard let client = sharedClient() else { note("resolve:no-client"); return nil }
        harvest(client)
        guard let hostPID = (read("_hostProcessIdentifier", from: controller) as? NSNumber)?.intValue,
              hostPID > 0 else { note("resolve:no-host-pid"); return nil }
        guard let bundle = currentAppearance[hostPID] else { note("resolve:pid-mismatch-or-unseen"); return nil }
        note("resolve:pid-matched")
        return bundle
    }

    private static func harvest(_ client: NSObject) {
        guard let state = read("currentClientState", from: client) as? NSObject,
              let bundle = read("sourceBundleIdentifier", from: state) as? String,
              let pid = (read("processIdentifier", from: state) as? NSNumber)?.intValue,
              pid > 0, !bundle.isEmpty else { note("harvest:no-complete-state"); return }
        // Same upstream max bound, but no history survives a new appearance.
        if currentAppearance[pid] == nil, currentAppearance.count >= 64 { currentAppearance.removeAll() }
        currentAppearance[pid] = bundle
    }

    private static func sharedClient() -> NSObject? {
        for name in ["_UIKeyboardArbiterClient", "UIKeyboardArbiterClient"] {
            guard let cls = NSClassFromString(name) as? NSObject.Type else { continue }
            let object = cls as AnyObject
            let selector = NSSelectorFromString("automaticSharedArbiterClient")
            guard object.responds(to: selector) else { continue }
            return object.perform(selector)?.takeUnretainedValue() as? NSObject
        }
        return nil
    }

    private static func read(_ key: String, from object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static func note(_ status: String) {
        guard status != lastDiagnostic, diagnosticCount < 8 else { return }
        lastDiagnostic = status
        diagnosticCount += 1
        // Fixed states only: no bundle ID, PID, document context, URL or user text.
        logger.notice("host-probe \(status, privacy: .public)")
    }
}
