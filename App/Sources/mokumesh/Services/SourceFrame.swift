// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeshLink

/// 映す 1 枚。専用の受け渡しから来たものも、Syphon から来たものも、この形にそろえて描く。
///
/// 描いている投入が終わるまで、描く側がこれを持ち続ける。専用の受け渡しの 1 枚は、
/// 最後の持ち手が手放したときに面が送り手へ返る (`LinkFrame` の `deinit`)。
final class SourceFrame: @unchecked Sendable {
    enum Origin: Sendable {
        case link
        case syphon
    }

    let origin: Origin
    let texture: any MTLTexture
    /// 値に sRGB の曲線が掛かったまま読めるので、断片で外す (Syphon)。
    /// 専用の受け渡しは `_srgb` の形式で読むので、取るときに外れている。
    let decodesInShader: Bool
    /// 色が不透明度で乗算済みか (Syphon の慣習)。専用の受け渡しは straight。
    let premultiplied: Bool
    /// 受け手が受け取った瞬間の host time。
    let arrivedHostTime: UInt64
    /// 送り手が名乗ったフレーム番号 (専用の受け渡しだけ)。
    let frame: Int?
    /// 送り手が絵を受け取った瞬間の host time (専用の受け渡しだけ)。
    let handedHostTime: UInt64?
    /// 絵の上端に描かれていた、送り手が描いた瞬間の host time (計測のときだけ読む)。
    var drawnHostTime: UInt64?
    /// 専用の受け渡しの 1 枚。持っている間、面は送り手へ返らない。
    private let link: LinkFrame?

    init(link: LinkFrame, texture: any MTLTexture) {
        origin = .link
        self.texture = texture
        decodesInShader = false
        premultiplied = false
        arrivedHostTime = link.arrivedHostTime
        frame = link.frame
        handedHostTime = link.handedHostTime
        self.link = link
    }

    init(syphon texture: any MTLTexture, arrivedHostTime: UInt64) {
        origin = .syphon
        self.texture = texture
        decodesInShader = true
        premultiplied = true
        self.arrivedHostTime = arrivedHostTime
        frame = nil
        handedHostTime = nil
        link = nil
    }
}
