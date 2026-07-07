#include "RorkDeviceLwIP.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__linux__)
#include <errno.h>
#include <sys/random.h>
#endif

#include "lwip/init.h"
#include "lwip/ip6.h"
#include "lwip/mem.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"

/// Heap wrapper that binds one lwIP TCP control block to its Swift callback.
///
/// The stack owns list membership, while Swift owns the wrapper allocation.
/// lwIP owns `pcb` until close, abort, or its error callback clears the pointer.
struct rork_lwip_connection {
    /// Owning stack while this wrapper remains linked, otherwise `NULL`.
    rork_lwip_stack_t *stack;

    /// Active lwIP TCP control block, cleared before terminal callbacks.
    struct tcp_pcb *pcb;

    /// Borrowed synchronous event receiver supplied by Swift.
    rork_lwip_connection_callback_t callback;

    /// Borrowed pointer forwarded unchanged to `callback`.
    void *callback_context;

    /// Previous wrapper in the owning stack's intrusive list.
    struct rork_lwip_connection *previous;

    /// Next wrapper in the owning stack's intrusive list.
    struct rork_lwip_connection *next;
};

/// Heap owner for one lwIP interface and its intrusive connection list.
///
/// Callback pointers and contexts are borrowed from Swift for the complete
/// lifetime of the stack.
struct rork_lwip_stack {
    /// Embedded lwIP interface carrying this stack's IPv6 packets.
    struct netif network_interface;

    /// Borrowed synchronous receiver for emitted IPv6 packets.
    rork_lwip_output_callback_t output_callback;

    /// Borrowed pointer forwarded unchanged to `output_callback`.
    void *output_context;

    /// Head of the intrusive list of Swift-owned connection wrappers.
    rork_lwip_connection_t *connections;
};

/// Records whether process-wide lwIP initialization has completed.
///
/// Access is confined to the shared serialized execution context required by
/// the public API.
static int rork_lwip_initialized = 0;

/// Forwards one connection event when its Swift callback is still installed.
///
/// Payload storage is borrowed and remains valid only for the synchronous
/// duration of this call.
static void rork_lwip_emit_connection_event(
    rork_lwip_connection_t *connection,
    rork_lwip_connection_event_t event,
    const uint8_t *data,
    size_t length,
    int error_code
) {
    if (connection != NULL && connection->callback != NULL) {
        connection->callback(
            connection->callback_context,
            event,
            data,
            length,
            error_code
        );
    }
}

/// Flattens an lwIP packet chain and forwards one complete IPv6 packet to Swift.
///
/// lwIP retains ownership of `packet`. The temporary contiguous allocation is
/// released immediately after the synchronous output callback returns.
static err_t rork_lwip_network_output(
    struct netif *network_interface,
    struct pbuf *packet,
    const ip6_addr_t *destination
) {
    (void)destination;
    rork_lwip_stack_t *stack = network_interface->state;
    if (stack == NULL || stack->output_callback == NULL) {
        return ERR_IF;
    }

    uint8_t *bytes = malloc(packet->tot_len);
    if (bytes == NULL) {
        return ERR_MEM;
    }

    pbuf_copy_partial(packet, bytes, packet->tot_len, 0);
    stack->output_callback(
        stack->output_context,
        bytes,
        packet->tot_len
    );
    free(bytes);
    return ERR_OK;
}

/// Configures the output function for a newly allocated network interface.
///
/// `netif_add_noaddr` installs the owning stack in `state` before invoking this
/// initializer.
static err_t rork_lwip_network_interface_initialize(
    struct netif *network_interface
) {
    rork_lwip_stack_t *stack = network_interface->state;
    if (stack == NULL) {
        return ERR_ARG;
    }

    network_interface->name[0] = 'r';
    network_interface->name[1] = 'k';
    network_interface->output_ip6 = rork_lwip_network_output;
    return ERR_OK;
}

/// Handles completion of an outbound TCP handshake.
///
/// A failed handshake leaves wrapper cleanup to the Swift owner after the error
/// event has made its asynchronous state terminal.
static err_t rork_lwip_connection_did_connect(
    void *argument,
    struct tcp_pcb *pcb,
    err_t error
) {
    rork_lwip_connection_t *connection = argument;
    if (connection == NULL) {
        return ERR_ARG;
    }
    if (error != ERR_OK) {
        rork_lwip_emit_connection_event(
            connection,
            RORK_LWIP_CONNECTION_ERROR,
            NULL,
            0,
            error
        );
        return error;
    }

    connection->pcb = pcb;
    rork_lwip_emit_connection_event(
        connection,
        RORK_LWIP_CONNECTION_CONNECTED,
        NULL,
        0,
        ERR_OK
    );
    return ERR_OK;
}

/// Processes received TCP payloads, protocol failures, and orderly remote close.
///
/// Returning `ERR_MEM` without freeing a data packet asks lwIP to retry delivery
/// later. Accepted payloads are copied for the callback and then released
/// without advancing the receive window; Swift acknowledges consumed bytes
/// separately through `rork_lwip_connection_received`.
static err_t rork_lwip_connection_did_receive(
    void *argument,
    struct tcp_pcb *pcb,
    struct pbuf *packet,
    err_t error
) {
    rork_lwip_connection_t *connection = argument;
    if (connection == NULL) {
        if (packet != NULL) {
            pbuf_free(packet);
        }
        return ERR_ARG;
    }
    if (error != ERR_OK) {
        if (packet != NULL) {
            pbuf_free(packet);
        }
        rork_lwip_emit_connection_event(
            connection,
            RORK_LWIP_CONNECTION_ERROR,
            NULL,
            0,
            error
        );
        return error;
    }
    if (packet == NULL) {
        connection->pcb = NULL;
        if (tcp_close(pcb) != ERR_OK) {
            tcp_abort(pcb);
        }
        rork_lwip_emit_connection_event(
            connection,
            RORK_LWIP_CONNECTION_CLOSED,
            NULL,
            0,
            ERR_OK
        );
        return ERR_OK;
    }

    uint8_t *bytes = malloc(packet->tot_len);
    if (bytes == NULL) {
        return ERR_MEM;
    }
    pbuf_copy_partial(packet, bytes, packet->tot_len, 0);
    rork_lwip_emit_connection_event(
        connection,
        RORK_LWIP_CONNECTION_DATA,
        bytes,
        packet->tot_len,
        ERR_OK
    );
    free(bytes);
    pbuf_free(packet);
    return ERR_OK;
}

/// Reports newly available send capacity after lwIP acknowledges queued bytes.
static err_t rork_lwip_connection_did_send(
    void *argument,
    struct tcp_pcb *pcb,
    u16_t length
) {
    (void)pcb;
    (void)length;
    rork_lwip_emit_connection_event(
        argument,
        RORK_LWIP_CONNECTION_WRITABLE,
        NULL,
        0,
        ERR_OK
    );
    return ERR_OK;
}

/// Periodically wakes a sender that may be waiting on TCP send capacity.
///
/// Poll notifications are advisory: the subsequent write still checks the
/// current send window and may return zero again.
static err_t rork_lwip_connection_did_poll(
    void *argument,
    struct tcp_pcb *pcb
) {
    (void)pcb;
    rork_lwip_emit_connection_event(
        argument,
        RORK_LWIP_CONNECTION_WRITABLE,
        NULL,
        0,
        ERR_OK
    );
    return ERR_OK;
}

/// Handles terminal lwIP failures after lwIP has already released the PCB.
///
/// The wrapper remains allocated until Swift destroys it.
static void rork_lwip_connection_did_fail(
    void *argument,
    err_t error
) {
    rork_lwip_connection_t *connection = argument;
    if (connection == NULL) {
        return;
    }
    connection->pcb = NULL;
    rork_lwip_emit_connection_event(
        connection,
        RORK_LWIP_CONNECTION_ERROR,
        NULL,
        0,
        error
    );
}

/// Adds a connection wrapper to the owning stack's intrusive list.
///
/// The list allows stack teardown to abort every PCB without taking ownership
/// of the Swift-managed wrapper allocations.
static void rork_lwip_stack_link_connection(
    rork_lwip_stack_t *stack,
    rork_lwip_connection_t *connection
) {
    connection->next = stack->connections;
    if (stack->connections != NULL) {
        stack->connections->previous = connection;
    }
    stack->connections = connection;
}

/// Removes a connection wrapper from its owning stack exactly once.
///
/// Detached wrappers remain valid and can still be destroyed safely after their
/// stack has already been released.
static void rork_lwip_stack_unlink_connection(
    rork_lwip_connection_t *connection
) {
    if (connection == NULL || connection->stack == NULL) {
        return;
    }

    if (connection->previous != NULL) {
        connection->previous->next = connection->next;
    } else {
        connection->stack->connections = connection->next;
    }
    if (connection->next != NULL) {
        connection->next->previous = connection->previous;
    }
    connection->stack = NULL;
    connection->previous = NULL;
    connection->next = NULL;
}

rork_lwip_stack_t *rork_lwip_stack_create(
    const uint8_t local_address[16],
    uint16_t maximum_transmission_unit,
    rork_lwip_output_callback_t output_callback,
    void *output_context
) {
    if (
        local_address == NULL ||
        maximum_transmission_unit < 1280 ||
        output_callback == NULL
    ) {
        return NULL;
    }

    if (!rork_lwip_initialized) {
        lwip_init();
        rork_lwip_initialized = 1;
    }

    rork_lwip_stack_t *stack = calloc(1, sizeof(*stack));
    if (stack == NULL) {
        return NULL;
    }
    stack->output_callback = output_callback;
    stack->output_context = output_context;

    if (
        netif_add_noaddr(
            &stack->network_interface,
            stack,
            rork_lwip_network_interface_initialize,
            ip6_input
        ) == NULL
    ) {
        free(stack);
        return NULL;
    }

    stack->network_interface.mtu = maximum_transmission_unit;
    ip6_addr_t address;
    memcpy(address.addr, local_address, sizeof(address.addr));
    ip6_addr_clear_zone(&address);
    netif_ip6_addr_set(&stack->network_interface, 0, &address);
    netif_ip6_addr_set_state(
        &stack->network_interface,
        0,
        IP6_ADDR_PREFERRED
    );
    netif_set_default(&stack->network_interface);
    netif_set_link_up(&stack->network_interface);
    netif_set_up(&stack->network_interface);
    return stack;
}

void rork_lwip_stack_destroy(rork_lwip_stack_t *stack) {
    if (stack == NULL) {
        return;
    }

    rork_lwip_connection_t *connection = stack->connections;
    while (connection != NULL) {
        rork_lwip_connection_t *next = connection->next;
        if (connection->pcb != NULL) {
            tcp_arg(connection->pcb, NULL);
            tcp_abort(connection->pcb);
            connection->pcb = NULL;
        }
        connection->stack = NULL;
        connection->previous = NULL;
        connection->next = NULL;
        connection = next;
    }
    stack->connections = NULL;

    netif_set_down(&stack->network_interface);
    netif_set_link_down(&stack->network_interface);
    netif_remove(&stack->network_interface);
    free(stack);
}

int rork_lwip_stack_input(
    rork_lwip_stack_t *stack,
    const uint8_t *packet,
    size_t length
) {
    if (
        stack == NULL ||
        packet == NULL ||
        length < 40 ||
        length > UINT16_MAX
    ) {
        return ERR_ARG;
    }

    // PBUF_RAM allocates exactly `length` bytes in one contiguous buffer.
    // Pool buffers would either waste a full jumbo-sized block on every
    // 60-byte ACK or chain ten buffers per jumbo packet; with malloc-backed
    // memory (MEM_LIBC_MALLOC) the pool grants nothing in exchange.
    struct pbuf *buffer = pbuf_alloc(
        PBUF_RAW,
        (u16_t)length,
        PBUF_RAM
    );
    if (buffer == NULL) {
        return ERR_MEM;
    }
    err_t result = pbuf_take(buffer, packet, length);
    if (result != ERR_OK) {
        pbuf_free(buffer);
        return result;
    }

    return stack->network_interface.input(
        buffer,
        &stack->network_interface
    );
}

void rork_lwip_stack_poll(rork_lwip_stack_t *stack) {
    if (stack != NULL) {
        sys_check_timeouts();
    }
}

void rork_lwip_stack_stats_read(
    rork_lwip_stack_t *stack,
    rork_lwip_stack_stats_t *stats
) {
    if (stack == NULL || stats == NULL) {
        return;
    }

    stats->tcp_segments_sent = lwip_stats.tcp.xmit;
    stats->tcp_segments_received = lwip_stats.tcp.recv;
    stats->tcp_segments_retransmitted = lwip_stats.mib2.tcpretranssegs;
    stats->tcp_drops = lwip_stats.tcp.drop;
    stats->tcp_errors = (uint32_t)lwip_stats.tcp.chkerr
        + lwip_stats.tcp.lenerr
        + lwip_stats.tcp.memerr
        + lwip_stats.tcp.rterr
        + lwip_stats.tcp.proterr
        + lwip_stats.tcp.opterr
        + lwip_stats.tcp.err;
    stats->ip6_packets_sent = lwip_stats.ip6.xmit;
    stats->ip6_packets_received = lwip_stats.ip6.recv;
    stats->ip6_drops = lwip_stats.ip6.drop;
}

rork_lwip_connection_t *rork_lwip_connection_create(
    rork_lwip_stack_t *stack,
    const uint8_t remote_address[16],
    uint16_t remote_port,
    rork_lwip_connection_callback_t callback,
    void *callback_context
) {
    if (
        stack == NULL ||
        remote_address == NULL ||
        remote_port == 0 ||
        callback == NULL
    ) {
        return NULL;
    }

    rork_lwip_connection_t *connection = calloc(
        1,
        sizeof(*connection)
    );
    if (connection == NULL) {
        return NULL;
    }
    connection->stack = stack;
    connection->callback = callback;
    connection->callback_context = callback_context;

    struct tcp_pcb *pcb = tcp_new_ip6();
    if (pcb == NULL) {
        free(connection);
        return NULL;
    }
    connection->pcb = pcb;
    tcp_bind_netif(pcb, &stack->network_interface);
    tcp_arg(pcb, connection);
    tcp_recv(pcb, rork_lwip_connection_did_receive);
    tcp_sent(pcb, rork_lwip_connection_did_send);
    tcp_poll(pcb, rork_lwip_connection_did_poll, 2);
    tcp_err(pcb, rork_lwip_connection_did_fail);
    tcp_nagle_disable(pcb);
    pcb->so_options |= SOF_KEEPALIVE;
    pcb->keep_idle = 30000;
    pcb->keep_intvl = 1000;
    pcb->keep_cnt = 5;

    ip_addr_t address;
    IP_SET_TYPE_VAL(address, IPADDR_TYPE_V6);
    memcpy(ip_2_ip6(&address)->addr, remote_address, 16);
    ip6_addr_clear_zone(ip_2_ip6(&address));

    err_t result = tcp_connect(
        pcb,
        &address,
        remote_port,
        rork_lwip_connection_did_connect
    );
    if (result != ERR_OK) {
        tcp_arg(pcb, NULL);
        tcp_abort(pcb);
        free(connection);
        return NULL;
    }

    rork_lwip_stack_link_connection(stack, connection);
    return connection;
}

ptrdiff_t rork_lwip_connection_write(
    rork_lwip_connection_t *connection,
    const uint8_t *bytes,
    size_t length
) {
    if (
        connection == NULL ||
        connection->pcb == NULL ||
        bytes == NULL
    ) {
        return ERR_CONN;
    }
    if (length == 0) {
        return 0;
    }

    // With RFC 7323 window scaling enabled the send buffer is a 32-bit
    // quantity; a u16 here truncated a full one-megabyte buffer to zero and
    // stalled every bulk send before it started.
    tcpwnd_size_t available = tcp_sndbuf(connection->pcb);
    if (available == 0) {
        return 0;
    }
    size_t accepted = length;
    if (accepted > available) {
        accepted = available;
    }
    if (accepted > UINT16_MAX) {
        accepted = UINT16_MAX;
    }

    err_t result = tcp_write(
        connection->pcb,
        bytes,
        (u16_t)accepted,
        TCP_WRITE_FLAG_COPY
    );
    if (result == ERR_MEM) {
        return 0;
    }
    if (result != ERR_OK) {
        return result;
    }
    // `tcp_write` has already copied these bytes into lwIP's send queue. A
    // transient output failure must not make the caller enqueue duplicates;
    // lwIP's timers will retry transmission of the accepted data.
    (void)tcp_output(connection->pcb);
    return (ptrdiff_t)accepted;
}

void rork_lwip_connection_received(
    rork_lwip_connection_t *connection,
    size_t length
) {
    if (connection == NULL || connection->pcb == NULL) {
        return;
    }

    while (length > 0) {
        u16_t acknowledged = length > UINT16_MAX
            ? UINT16_MAX
            : (u16_t)length;
        tcp_recved(connection->pcb, acknowledged);
        length -= acknowledged;
    }
}

void rork_lwip_connection_close(
    rork_lwip_connection_t *connection
) {
    if (connection == NULL || connection->pcb == NULL) {
        return;
    }

    struct tcp_pcb *pcb = connection->pcb;
    connection->pcb = NULL;
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_sent(pcb, NULL);
    tcp_poll(pcb, NULL, 0);
    tcp_err(pcb, NULL);
    if (tcp_close(pcb) != ERR_OK) {
        tcp_abort(pcb);
    }
}

void rork_lwip_connection_destroy(
    rork_lwip_connection_t *connection
) {
    if (connection == NULL) {
        return;
    }
    rork_lwip_connection_close(connection);
    rork_lwip_stack_unlink_connection(connection);
    free(connection);
}

/// Supplies entropy for lwIP sequence numbers and protocol identifiers.
///
/// Apple and FreeBSD platforms provide `arc4random_buf`, while Linux uses
/// `getrandom`. The C runtime fallback remains available for platforms without
/// either API.
uint32_t rork_lwip_random(void) {
    uint32_t value = 0;
#if defined(__APPLE__) || defined(__FreeBSD__)
    arc4random_buf(&value, sizeof(value));
#elif defined(__linux__)
    size_t offset = 0;
    while (offset < sizeof(value)) {
        ssize_t result = getrandom(
            ((uint8_t *)&value) + offset,
            sizeof(value) - offset,
            0
        );
        if (result > 0) {
            offset += (size_t)result;
            continue;
        }
        if (result < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    if (offset == sizeof(value)) {
        return value;
    }
#endif
    value = (uint32_t)rand();
    value ^= (uint32_t)rand() << 16;
    return value;
}

/// Returns monotonic milliseconds using lwIP's wrapping 32-bit clock format.
///
/// lwIP computes elapsed time with unsigned arithmetic, so truncation and
/// periodic wraparound are intentional.
u32_t sys_now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (u32_t)(
        ((uint64_t)time.tv_sec * 1000) +
        ((uint64_t)time.tv_nsec / 1000000)
    );
}

/// Provides lwIP's scheduler tick value using the same monotonic clock.
u32_t sys_jiffies(void) {
    return sys_now();
}
