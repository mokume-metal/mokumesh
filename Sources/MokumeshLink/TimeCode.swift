// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface

/// 絵の上端に描いた host time を読み書きする決まり。遅れの計測のためにある。
///
/// 送り手は上端に、幅 ``cellWidth``・高さ ``cellHeight`` 画素のマスを ``bits`` 個並べ、
/// host time の下位から順に白 (1) と黒 (0) で塗る。受け手は各マスの中心の画素の緑の成分で
/// 読む。絵が通った道 (専用の受け渡し・Syphon) によらず同じ物差しで測るため、時刻は
/// メッセージではなく絵そのものに載せる。
public enum TimeCode {
    public static let bits = 64
    public static let cellWidth = 16
    public static let cellHeight = 8

    /// 面の上端から時刻を読む。面が狭すぎれば `nil`。
    ///
    /// - Parameter greenOffset: 1 画素の中で緑の成分が何バイト目か (RGBA でも BGRA でも 1)。
    public static func read(_ surface: IOSurfaceRef, greenOffset: Int = 1) -> UInt64? {
        guard IOSurfaceGetWidth(surface) >= bits * cellWidth, IOSurfaceGetHeight(surface) >= cellHeight else {
            return nil
        }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let row = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            + IOSurfaceGetBytesPerRow(surface) * (cellHeight / 2)
        let bytesPerPixel = IOSurfaceGetBytesPerElement(surface)
        var value: UInt64 = 0
        for bit in 0..<bits {
            let x = bit * cellWidth + cellWidth / 2
            if row[x * bytesPerPixel + greenOffset] > 127 { value |= 1 << UInt64(bit) }
        }
        return value
    }
}
