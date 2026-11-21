// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import SafariServices
import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredBarTintColor = UIColor(red: 0.045, green: 0.058, blue: 0.096, alpha: 1.0)
        vc.preferredControlTintColor = UIColor(red: 0.82, green: 0.90, blue: 1.0, alpha: 1.0)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// 与 firmware/QemuRamfb.c 中 patched QemuRamfbDxe 的 18 档 GOP 模式一一对应。
/// 固件还支持任意自定义尺寸，这里只暴露标准档位。
enum GuestResolution: String, CaseIterable, Identifiable {
    case vga       = "640x480"
    case svga      = "800x600"
    case xga       = "1024x768"
    case hd720     = "1280x720"
    case wxga      = "1280x800"
    case sxga      = "1280x1024"
    case hd768     = "1366x768"
    case wxgaPlus  = "1440x900"
    case hd900     = "1600x900"
    case uxga      = "1600x1200"
    case wsxga     = "1680x1050"
    case fhd       = "1920x1080"
    case wuxga     = "1920x1200"
    case qwxga     = "2048x1152"
    case qhd       = "2560x1440"
    case wqxga     = "2560x1600"
    case wqxgaPlus = "2880x1800"
    case uhd       = "3840x2160"

    var id: String { rawValue }

    var displayName: String {
        let parts = rawValue.split(separator: "x")
        guard parts.count == 2 else { return rawValue }
        return "\(parts[0]) × \(parts[1])"
    }

    /// 手机屏幕上常用且帧缓冲带宽可控的档位。
    var isRecommended: Bool {
        switch self {
        case .svga, .xga, .hd720, .wxga, .hd768, .hd900, .fhd, .qhd:
            return true
        default:
            return false
        }
    }
}

enum PostureMode: String, CaseIterable {
    case auto = "Auto"
    case laptop = "Laptop"
    case fullScreen = "Studio"

    var iconName: String {
        switch self {
        case .auto: return "sparkles"
        case .laptop: return "laptopcomputer"
        case .fullScreen: return "ipad.landscape"
        }
    }

    var localizedName: String {
        switch self {
        case .auto: return "自动"
        case .laptop: return "笔记本"
        case .fullScreen: return "工作台"
        }
    }
}

enum DeckLayout: String, CaseIterable {
    case split = "Split"
    case trackpad = "Trackpad"
    case keyboard = "Keyboard"

    var iconName: String {
        switch self {
        case .split: return "laptopcomputer"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .keyboard: return "keyboard"
        }
    }

    var localizedName: String {
        switch self {
        case .split: return "分屏"
        case .trackpad: return "触控板"
        case .keyboard: return "键盘"
        }
    }

    var next: DeckLayout {
        switch self {
        case .split: return .trackpad
        case .trackpad: return .keyboard
        case .keyboard: return .split
        }
    }
}

@MainActor
final class VMViewModel: ObservableObject {
    @Published var isJITLive: Bool = false
    @Published var isDebuggerAttached: Bool = false
    @Published var isVMRunning: Bool = false
    @Published var isUnpacking: Bool = false
    @Published var unpackProgress: Double = 0
    @Published var jitStatusText: String = "正在检查 JIT..."
    @Published var vmStatusText: String = "正在初始化..."
    @Published var fbWidth: UInt32 = 0
    @Published var fbHeight: UInt32 = 0
    @Published var presentedFrames: UInt64 = 0
    @Published var availableMemoryMB: UInt64 = 0

    @Published var usbKeyboardReady: Bool = false
    @Published var usbTabletReady: Bool = false
    @Published var usbEventsDelivered: UInt64 = 0

    // iOS 27.1 UIHinge state (0 = unknown, 1 = closed, 2 = partiallyOpen, 3 = fullyOpen)
    @Published var hingeStatusRaw: Int = 0
    @Published var hingeAngleDegrees: Double? = nil

    @Published var postureMode: PostureMode = .auto
    @Published var deckLayout: DeckLayout = .split
    @Published var controlBarVisible: Bool = true
    @Published var trackpadMode: Bool = false
    @Published var rightClickArmed: Bool = false
    @Published var systemKeyboardVisible: Bool = false
    @Published var activeSafariURL: IdentifiableURL? = nil
    @Published var useSafariForOAuth: Bool = WinIOSBridge.shared.useSafariForGuestLinks
    @Published var resolutionPreset: GuestResolution = .fhd {
        didSet {
            UserDefaults.standard.set(resolutionPreset.rawValue, forKey: "winios.resolutionPreset")
            WinIOSBridge.shared.resolutionPreset = resolutionPreset.rawValue
        }
    }

    private var didAutoLaunchAttempt = false
    private var oauthPollTimer: Timer? = nil

    init() {
        let bridge = WinIOSBridge.shared
        if let saved = UserDefaults.standard.string(forKey: "winios.resolutionPreset"),
           let preset = GuestResolution(rawValue: saved) {
            resolutionPreset = preset
        }
        bridge.resolutionPreset = resolutionPreset.rawValue
        bridge.installTrapGuard()
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in
                self?.syncFromBridge()
            }
        }
        syncFromBridge()
        startOAuthPoller()
        Task { @MainActor [weak self] in
            self?.onAppBecameActive()
        }
    }

    private func startOAuthPoller() {
        oauthPollTimer?.invalidate()
        oauthPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let b = WinIOSBridge.shared
                if b.takeGuestOAuthDone() {
                    if self.activeSafariURL != nil {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.activeSafariURL = nil
                    }
                }
                if let urlStr = b.takeGuestOpenURL(), let u = URL(string: urlStr) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.activeSafariURL = IdentifiableURL(url: u)
                }
            }
        }
    }

    func toggleOAuthBrowserMode() {
        useSafariForOAuth.toggle()
        WinIOSBridge.shared.useSafariForGuestLinks = useSafariForOAuth
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func isLaptopLayoutActive(for size: CGSize) -> Bool {
        switch postureMode {
        case .laptop:
            return true
        case .fullScreen:
            return false
        case .auto:
            // Hardware hinge folded into laptop posture (partiallyOpen == 2, or live hinge angle 30°..166°)
            if hingeStatusRaw == 2 {
                return true
            }
            if let deg = hingeAngleDegrees {
                return deg >= 30.0 && deg <= 166.0
            }
            // Fallback when UIHinge hasn't reported yet: portrait inner screen defaults to Laptop
            let isUnfoldedInner = max(size.width, size.height) > 780 && min(size.width, size.height) > 580
            if hingeStatusRaw == 0 && isUnfoldedInner && size.height > size.width {
                return true
            }
            return false
        }
    }

    func updateHinge(statusRaw: Int, angleDegrees: Double?, viewportSize: CGSize) {
        let wasPartiallyOpen = (hingeStatusRaw == 2)
        hingeStatusRaw = statusRaw
        hingeAngleDegrees = angleDegrees
        if postureMode == .auto && statusRaw == 2 && !wasPartiallyOpen {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            SceneOrientationController.alignForLaptopPostureIfLandscape(size: viewportSize)
        }
    }

    func cyclePostureMode(viewportSize: CGSize) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch postureMode {
        case .auto:
            postureMode = .laptop
            SceneOrientationController.alignForLaptopPostureIfLandscape(size: viewportSize)
        case .laptop:
            postureMode = .fullScreen
        case .fullScreen:
            postureMode = .auto
        }
    }

    func launchGuestEdgeBrowser() {
        // Win+R -> "msedge" -> Enter
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            let msedgeHids: [UInt8] = [0x10, 0x16, 0x08, 0x07, 0x0a, 0x08, 0x28] // m s e d g e Enter
            for (idx, code) in msedgeHids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.045) {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
        }
    }

    func launchGuestAntigravity() {
        // Win+R -> "antigravity" -> Enter (registered in HKCU\...\App Paths\antigravity.exe)
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            // a n t i g r a v i t y Enter
            let agHids: [UInt8] = [0x04, 0x11, 0x17, 0x0c, 0x0a, 0x15, 0x04, 0x19, 0x0c, 0x17, 0x1c, 0x28]
            for (idx, code) in agHids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.040) {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
        }
    }

    func launchGuestPaint() {
        // Win+R -> "mspaint" -> Enter
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            // m s p a i n t Enter
            let paintHids: [UInt8] = [0x10, 0x16, 0x13, 0x04, 0x0c, 0x11, 0x17, 0x28]
            for (idx, code) in paintHids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.042) {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
        }
    }

    func syncFromBridge() {
        let b = WinIOSBridge.shared
        isJITLive = b.isJITLive
        isDebuggerAttached = b.isDebuggerAttached
        isVMRunning = b.isVMRunning
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        jitStatusText = b.jitStatusText
        vmStatusText = b.vmStatusText
        fbWidth = b.framebufferWidth
        fbHeight = b.framebufferHeight
        presentedFrames = b.presentedFrames
        availableMemoryMB = b.availableMemoryMB
        usbKeyboardReady = b.usbKeyboardReady
        usbTabletReady = b.usbTabletReady
        usbEventsDelivered = b.usbEventsDelivered
    }

    func onAppBecameActive() {
        let b = WinIOSBridge.shared
        if !b.isJITLive && b.isDebuggerAttached {
            _ = b.tryAcquireJIT(true)
        }
        syncFromBridge()
        if b.isJITLive && !b.isVMRunning && !b.isUnpacking && b.hasProvisionedMachine() && !didAutoLaunchAttempt {
            didAutoLaunchAttempt = true
            b.prepareAndStart(with: nil)
            syncFromBridge()
        }
    }

    func startOrRetry() {
        didAutoLaunchAttempt = true
        WinIOSBridge.shared.prepareAndStart(with: nil)
        syncFromBridge()
    }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
        ]
        if let scriptPath = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
           let script = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           let data = script.data(using: .utf8) {
            components.queryItems?.append(
                URLQueryItem(name: "script-data", value: data.base64EncodedString())
            )
        }
        if let url = components.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
