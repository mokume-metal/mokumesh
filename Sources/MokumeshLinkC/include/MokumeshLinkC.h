// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// mokumesh の受け渡しの、mach のメッセージの層。
//
// Swift から port descriptor を持つ mach のメッセージを組むのは、構造体の並びと
// 可変長の扱いが Swift の型に乗りにくいので、ここで固定の形に閉じる。
// 1 通は常に「descriptor 4 本 + 固定長の中身」で、使わない descriptor は
// MACH_PORT_NULL を持つ (中身の位置を種類によらず一定にするため)。

#ifndef MOKUMESH_LINK_C_H
#define MOKUMESH_LINK_C_H

#include <mach/mach.h>
#include <stdint.h>

#define MOKUMESH_PORT_COUNT 4
#define MOKUMESH_STREAM_LENGTH 64

/// 約束の版。中身の形を変えたら上げる。受け手は知らない版のメッセージを捨てる。
#define MOKUMESH_PROTOCOL_VERSION 1

typedef enum : uint32_t {
    /// 送り手 → 受け手: 映像を始める・大きさや形式が変わった。ports[0] = 送り手の受け口
    MokumeshKindHello = 1,
    /// 受け手 → 送り手: 面を渡す。ports[0..surfaceCount-1] = IOSurface の mach port
    MokumeshKindSurfaces = 2,
    /// 送り手 → 受け手: slot の面に 1 枚を書き終えた
    MokumeshKindFrame = 3,
    /// 受け手 → 送り手: slot の面を読み終えたので、また書いてよい
    MokumeshKindRelease = 4,
    /// 送り手 → 受け手: 映像を終える
    MokumeshKindBye = 5,
    /// (通ではない) 相手の受け口が無くなった — 相手のプロセスが終わったか落ちた。ports[0] = 死んだ名前。
    /// 受け手は送り手の受け口について、送り手は受け手の受け口について受ける
    MokumeshKindSenderGone = 6,
    /// 受け手 → 送り手: 映す面の情報 (大きさ・形・マスク・UV の配置) を返す。
    /// 番号だけを取ってあり、中身の形は面を返す段で決める (ADR-0001 決定 3)。送り手はいま読み捨てる
    MokumeshKindSurfaceInfo = 7,
} MokumeshKind;

typedef struct {
    uint32_t kind;
    uint32_t version;
    /// 面の組の世代。HELLO を受けるたびに受け手が進める。古い世代の FRAME / RELEASE は捨てる
    uint32_t generation;
    uint32_t slot;
    uint32_t width;
    uint32_t height;
    /// 画素の形式 (Swift 側の LinkFormat の生の値)
    uint32_t format;
    uint32_t surfaceCount;
    /// 送り手のフレーム番号
    int64_t frame;
    /// 送り手の時刻 (秒)
    double time;
    /// 送り手が絵を受け取った瞬間の host time (mach_absolute_time)
    uint64_t handedHostTime;
    /// 送り手の面への書き込みが GPU で終わった瞬間の host time
    uint64_t readyHostTime;
    /// 映像の名前 (NUL 終端)
    char stream[MOKUMESH_STREAM_LENGTH];
} MokumeshPayload;

/// bootstrap に名前を登録し、受け口 (receive right) を得る。
kern_return_t mokumesh_check_in(const char *name, mach_port_t *outReceive);

/// bootstrap から名前を引き、送り先 (send right) を得る。
kern_return_t mokumesh_look_up(const char *name, mach_port_t *outSend);

/// 名前の無い受け口を作る (receive right と、それに対する send right を 1 つ)。
kern_return_t mokumesh_allocate_port(mach_port_t *outReceive);

/// 受け口に溜められる通の数を、既定 (5 通) から大きくする。受け手の受け口には、複数の
/// 送り手・映像の FRAME が集まる。溜まりきると送り手の送りが時間切れになり、送り手は
/// 受け手が居なくなったとみなして繋ぎ直してしまう。
/// (送り手の受け口へは、面の枚数を超える RELEASE が溜まらないので要らない)
kern_return_t mokumesh_enlarge_queue(mach_port_t port);

/// 受け口を壊す。待っている mokumesh_receive はエラーで戻る。
void mokumesh_destroy_receive(mach_port_t port);

/// send right を 1 つ手放す。
void mokumesh_release_send(mach_port_t port);

/// port が死んだら notify へ知らせを送るよう頼む。受けると mokumesh_receive が
/// MokumeshKindSenderGone として返す。
kern_return_t mokumesh_request_dead_name(mach_port_t port, mach_port_t notify);

/// mokumesh_request_dead_name の頼みを取り消す。send right を手放す前に呼ぶ — 頼んだまま
/// 手放すと、名前が消えたという別の知らせが届く。
void mokumesh_cancel_dead_name(mach_port_t port);

/// 1 通を送る。ports と dispositions は MOKUMESH_PORT_COUNT 本。timeoutMs は送りの待ちの上限。
kern_return_t mokumesh_send(
    mach_port_t destination, const MokumeshPayload *payload,
    const mach_port_t *ports, const mach_msg_type_name_t *dispositions,
    mach_msg_timeout_t timeoutMs);

/// 1 通を受ける。wait が 0 なら timeoutMs まで待ち (0 なら待たずに戻る)、0 以外なら届くまで待つ。
/// 受けた port の権利は呼んだ側が持つ (要らなければ mokumesh_release_send で手放す)。
kern_return_t mokumesh_receive(
    mach_port_t port, MokumeshPayload *outPayload, mach_port_t *outPorts,
    int wait, mach_msg_timeout_t timeoutMs);

#endif
