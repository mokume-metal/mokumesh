// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor

/// 繋がっている表示装置を見張る。繋いだ・外した・解像度を変えたときに知らせる。
@MainActor
final class DisplayMonitor {
    /// 表示装置の組が変わった。
    var onChange: ([DisplayInfo]) -> Void = { _ in }
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange(self.displays)
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    var displays: [DisplayInfo] { NSScreen.screens.compactMap(Self.info) }

    /// 表示装置の識別子から画面を引く。
    func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == id }
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func info(_ screen: NSScreen) -> DisplayInfo? {
        guard let id = displayID(of: screen) else { return nil }
        let scale = screen.backingScaleFactor
        return DisplayInfo(
            id: id, name: screen.localizedName, pixelWidth: screen.frame.width * scale,
            pixelHeight: screen.frame.height * scale)
    }
}
