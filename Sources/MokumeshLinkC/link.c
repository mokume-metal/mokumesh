// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

#include "MokumeshLinkC.h"

#include <mach/notify.h>
#include <servers/bootstrap.h>
#include <string.h>

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[MOKUMESH_PORT_COUNT];
    MokumeshPayload payload;
} MokumeshMessage;

typedef struct {
    MokumeshMessage message;
    mach_msg_max_trailer_t trailer;
} MokumeshReceived;

kern_return_t mokumesh_check_in(const char *name, mach_port_t *outReceive) {
    // launchd に宣言していない名前でも、署名の無いプロセスから check_in できる
    // (2026-11-07 に macOS 27 で実測)。非推奨の bootstrap_register は使わない
    kern_return_t kr = bootstrap_check_in(bootstrap_port, name, outReceive);
    if (kr == KERN_SUCCESS) mokumesh_enlarge_queue(*outReceive);
    return kr;
}

kern_return_t mokumesh_look_up(const char *name, mach_port_t *outSend) {
    return bootstrap_look_up(bootstrap_port, name, outSend);
}

kern_return_t mokumesh_enlarge_queue(mach_port_t port) {
    mach_port_limits_t limits = { .mpl_qlimit = MACH_PORT_QLIMIT_LARGE };
    return mach_port_set_attributes(
        mach_task_self(), port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
        MACH_PORT_LIMITS_INFO_COUNT);
}

kern_return_t mokumesh_allocate_port(mach_port_t *outReceive) {
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, outReceive);
    if (kr != KERN_SUCCESS) return kr;
    return mach_port_insert_right(mach_task_self(), *outReceive, *outReceive, MACH_MSG_TYPE_MAKE_SEND);
}

void mokumesh_destroy_receive(mach_port_t port) {
    if (port == MACH_PORT_NULL) return;
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    // allocate で入れた send right も残っていれば外す (無ければ失敗するだけ)
    mach_port_deallocate(mach_task_self(), port);
}

void mokumesh_release_send(mach_port_t port) {
    if (port == MACH_PORT_NULL) return;
    mach_port_deallocate(mach_task_self(), port);
}

kern_return_t mokumesh_request_dead_name(mach_port_t port, mach_port_t notify) {
    mach_port_t previous = MACH_PORT_NULL;
    kern_return_t kr = mach_port_request_notification(
        mach_task_self(), port, MACH_NOTIFY_DEAD_NAME, 0, notify, MACH_MSG_TYPE_MAKE_SEND_ONCE,
        &previous);
    // 同じ名前へ頼み直したときは、前の頼みの send-once の権利が返ってくる
    if (previous != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), previous);
    return kr;
}

kern_return_t mokumesh_send(
    mach_port_t destination, const MokumeshPayload *payload,
    const mach_port_t *ports, const mach_msg_type_name_t *dispositions,
    mach_msg_timeout_t timeoutMs) {
    MokumeshMessage message;
    memset(&message, 0, sizeof message);
    message.header.msgh_bits =
        MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
    message.header.msgh_size = sizeof message;
    message.header.msgh_remote_port = destination;
    message.body.msgh_descriptor_count = MOKUMESH_PORT_COUNT;
    for (int index = 0; index < MOKUMESH_PORT_COUNT; index++) {
        message.ports[index].name = ports[index];
        message.ports[index].disposition =
            ports[index] == MACH_PORT_NULL ? MACH_MSG_TYPE_COPY_SEND : dispositions[index];
        message.ports[index].type = MACH_MSG_PORT_DESCRIPTOR;
    }
    message.payload = *payload;
    message.payload.version = MOKUMESH_PROTOCOL_VERSION;
    kern_return_t kr = mach_msg(
        &message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0,
        MACH_PORT_NULL, timeoutMs, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        // 送れなかった通の中で MOVE を指定した権利は、こちらに残ったまま。
        // 呼び手が二度手放さないよう、ここで片付ける
        for (int index = 0; index < MOKUMESH_PORT_COUNT; index++) {
            if (ports[index] != MACH_PORT_NULL && dispositions[index] == MACH_MSG_TYPE_MOVE_SEND) {
                mach_port_deallocate(mach_task_self(), ports[index]);
            }
        }
    }
    return kr;
}

kern_return_t mokumesh_receive(
    mach_port_t port, MokumeshPayload *outPayload, mach_port_t *outPorts,
    int wait, mach_msg_timeout_t timeoutMs) {
    MokumeshReceived received;
    memset(&received, 0, sizeof received);
    mach_msg_option_t options = MACH_RCV_MSG;
    if (!wait) options |= MACH_RCV_TIMEOUT;
    kern_return_t kr = mach_msg(
        &received.message.header, options, 0, sizeof received, port, timeoutMs, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return kr;
    mach_msg_header_t *header = &received.message.header;
    if (header->msgh_id == MACH_NOTIFY_DEAD_NAME) {
        // 知らせが持ってくる死んだ名前の参照は、呼び手が session と一緒に手放す
        mach_dead_name_notification_t *notification = (mach_dead_name_notification_t *)header;
        memset(outPayload, 0, sizeof *outPayload);
        outPayload->kind = MokumeshKindSenderGone;
        outPayload->version = MOKUMESH_PROTOCOL_VERSION;
        for (int index = 0; index < MOKUMESH_PORT_COUNT; index++) outPorts[index] = MACH_PORT_NULL;
        outPorts[0] = notification->not_port;
        return KERN_SUCCESS;
    }
    if (!(header->msgh_bits & MACH_MSGH_BITS_COMPLEX)
        || header->msgh_size < sizeof(MokumeshMessage)
        || received.message.body.msgh_descriptor_count != MOKUMESH_PORT_COUNT) {
        // 形の違う通 (他のものが名前を引いて送ってきたなど)。持たされた権利を片付けて捨てる
        mach_msg_destroy(header);
        return MACH_RCV_INVALID_DATA;
    }
    for (int index = 0; index < MOKUMESH_PORT_COUNT; index++) {
        outPorts[index] = received.message.ports[index].name;
    }
    *outPayload = received.message.payload;
    return KERN_SUCCESS;
}
