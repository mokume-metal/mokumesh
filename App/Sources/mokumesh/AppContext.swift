// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshEditor
import Observation

/// アプリの部品の束。`AppDelegate` (composition root) が組み立て、窓とビューへ渡す。
///
/// 編集の論理 (`document`・`session`) とサービス (`hub`・`displays`) を同じ束で渡すが、
/// ビューが変えてよいのは `session` の意図の関数を通したものだけである (ADR-0003 決定 1)。
@MainActor
final class AppContext {
    let document: EditorDocument
    let session: EditorSession
    let hub: FrameHub
    let displays: DisplayMonitor
    let status = AppStatus()
    /// 操作窓と出力の窓で共有する取り消し。
    let undoManager = UndoManager()
    /// 操作窓を出さずに映している (`--config`)。
    let isProduction: Bool

    init(document: EditorDocument, session: EditorSession, hub: FrameHub, displays: DisplayMonitor, isProduction: Bool) {
        self.document = document
        self.session = session
        self.hub = hub
        self.displays = displays
        self.isProduction = isProduction
        document.undoManager = undoManager
    }
}

/// 操作窓の下端に出す知らせ。
@MainActor
@Observable
final class AppStatus {
    /// 読み書きの結果など、最後の知らせ。
    var message: String?
    /// 受け手を起こせなかった訳。
    var receiverError: String?
}
