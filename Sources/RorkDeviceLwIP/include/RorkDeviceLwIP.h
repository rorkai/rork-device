#ifndef RORK_DEVICE_LWIP_H
#define RORK_DEVICE_LWIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque owner of one IPv6 lwIP network interface.
typedef struct rork_lwip_stack rork_lwip_stack_t;

/// Opaque owner of one TCP control block created through an lwIP stack.
typedef struct rork_lwip_connection rork_lwip_connection_t;

/// Events delivered synchronously through `rork_lwip_connection_callback_t`.
typedef enum rork_lwip_connection_event {
    /// The TCP handshake completed and the connection can send and receive data.
    RORK_LWIP_CONNECTION_CONNECTED = 1,

    /// `data` contains bytes received from the remote endpoint.
    RORK_LWIP_CONNECTION_DATA = 2,

    /// The send window may accept additional bytes.
    RORK_LWIP_CONNECTION_WRITABLE = 3,

    /// The remote endpoint completed an orderly close.
    RORK_LWIP_CONNECTION_CLOSED = 4,

    /// The connection failed and `error_code` contains an lwIP status code.
    RORK_LWIP_CONNECTION_ERROR = 5
} rork_lwip_connection_event_t;

/// Receives one complete IPv6 packet emitted toward the remote device.
///
/// The callback executes synchronously on the caller's serialized lwIP
/// execution context. `packet` is borrowed storage that remains valid only
/// until the callback returns; copy any bytes that must outlive the call.
///
/// - Parameters:
///   - context: The unchanged pointer supplied as `output_context` when the
///     stack was created.
///   - packet: Contiguous bytes containing one complete IPv6 packet.
///   - length: Number of readable bytes in `packet`.
typedef void (*rork_lwip_output_callback_t)(
    void *context,
    const uint8_t *packet,
    size_t length
);

/// Reports TCP state changes and received payloads for one connection.
///
/// The callback executes synchronously on the serialized lwIP execution
/// context. For `RORK_LWIP_CONNECTION_DATA`, `data` is borrowed storage valid
/// only until the callback returns. Other successful events provide `NULL`
/// data and a zero length. `RORK_LWIP_CONNECTION_ERROR` provides the failing
/// lwIP status in `error_code`.
///
/// A terminal event does not release the connection wrapper. The owner must
/// eventually call `rork_lwip_connection_destroy`.
///
/// - Parameters:
///   - context: The unchanged pointer supplied as `callback_context` when the
///     connection was created.
///   - event: Connection event being reported.
///   - data: Borrowed payload bytes for a data event, otherwise `NULL`.
///   - length: Number of readable bytes in `data`, otherwise zero.
///   - error_code: An lwIP status code for an error event, otherwise zero.
typedef void (*rork_lwip_connection_callback_t)(
    void *context,
    rork_lwip_connection_event_t event,
    const uint8_t *data,
    size_t length,
    int error_code
);

/// Creates and activates one IPv6-only lwIP interface.
///
/// lwIP keeps process-wide protocol state even when several interfaces exist.
/// The C layer does not provide synchronization, so every function operating
/// on any stack or connection must run on the same serialized execution
/// context. Callback contexts are borrowed and must remain valid until the
/// corresponding stack or connection is destroyed.
///
/// - Parameters:
///   - local_address: Sixteen network-order bytes containing the interface's
///     host-side IPv6 address.
///   - maximum_transmission_unit: Complete IPv6 packet size accepted by the
///     interface. Values below the IPv6 minimum of 1280 are rejected.
///   - output_callback: Synchronous receiver for packets emitted by lwIP.
///   - output_context: Caller-owned pointer forwarded to `output_callback`.
/// - Returns: An owned stack pointer, or `NULL` when validation, allocation, or
///   network-interface initialization fails.
rork_lwip_stack_t *rork_lwip_stack_create(
    const uint8_t local_address[16],
    uint16_t maximum_transmission_unit,
    rork_lwip_output_callback_t output_callback,
    void *output_context
);

/// Removes an interface and aborts every TCP control block still attached to it.
///
/// Connection wrappers are detached but remain allocated so their owners can
/// release them safely with `rork_lwip_connection_destroy`. No terminal
/// callbacks are emitted during stack destruction. `NULL` is accepted as a
/// no-op.
///
/// - Parameter stack: Owned stack pointer to invalidate and release.
void rork_lwip_stack_destroy(rork_lwip_stack_t *stack);

/// Delivers one complete IPv6 packet received from the remote device.
///
/// The bytes are copied into lwIP-owned packet storage before this function
/// returns, so the caller retains ownership of `packet`. TCP callbacks may run
/// synchronously while the packet is processed.
///
/// - Parameters:
///   - stack: Active stack that should receive the packet.
///   - packet: Raw IPv6 packet bytes, including the 40-byte IPv6 header.
///   - length: Packet size. Values below 40 or above `UINT16_MAX` are rejected.
/// - Returns: Zero on acceptance, or a negative lwIP error code.
int rork_lwip_stack_input(
    rork_lwip_stack_t *stack,
    const uint8_t *packet,
    size_t length
);

/// Runs expired process-wide lwIP TCP and IPv6 timers.
///
/// Timer processing may synchronously emit output and connection callbacks.
/// Passing `NULL` is a no-op. Because lwIP timer state is global, polling any
/// active stack advances timers for all stacks.
///
/// - Parameter stack: Any active stack used as a lifecycle guard.
void rork_lwip_stack_poll(rork_lwip_stack_t *stack);

/// Begins a TCP connection through a specific stack's IPv6 interface.
///
/// The returned wrapper owns the pending TCP control block and must eventually
/// be released with `rork_lwip_connection_destroy`, including after a terminal
/// callback. Handshake completion and failure are reported through `callback`
/// as input packets and timers are processed.
///
/// - Parameters:
///   - stack: Active stack whose interface must carry the connection.
///   - remote_address: Sixteen network-order bytes containing the destination
///     IPv6 address.
///   - remote_port: Nonzero TCP destination port.
///   - callback: Synchronous receiver for connection events.
///   - callback_context: Caller-owned pointer forwarded to `callback`.
/// - Returns: An owned connection wrapper, or `NULL` when validation,
///   allocation, or immediate TCP setup fails.
rork_lwip_connection_t *rork_lwip_connection_create(
    rork_lwip_stack_t *stack,
    const uint8_t remote_address[16],
    uint16_t remote_port,
    rork_lwip_connection_callback_t callback,
    void *callback_context
);

/// Copies bytes into the connection's TCP send queue.
///
/// A positive return value means those bytes are owned by lwIP and must not be
/// submitted again, even if immediate packet transmission was unsuccessful.
/// A zero result means the caller should wait for a writable event before
/// retrying. The caller retains ownership of `bytes`.
///
/// - Parameters:
///   - connection: Active connection wrapper.
///   - bytes: Source bytes to copy.
///   - length: Number of bytes available at `bytes`.
/// - Returns: Accepted byte count, zero for send-window backpressure, or a
///   negative lwIP error code.
ptrdiff_t rork_lwip_connection_write(
    rork_lwip_connection_t *connection,
    const uint8_t *bytes,
    size_t length
);

/// Returns consumed receive capacity to the connection's advertised TCP window.
///
/// Call this only for bytes previously delivered through data events and
/// consumed by the application. Counts larger than `UINT16_MAX` are applied in
/// multiple lwIP calls. A `NULL` or closed connection is ignored.
///
/// - Parameters:
///   - connection: Connection whose receive window should advance.
///   - length: Number of consumed payload bytes.
void rork_lwip_connection_received(
    rork_lwip_connection_t *connection,
    size_t length
);

/// Closes the TCP control block without releasing its connection wrapper.
///
/// Registered lwIP callbacks are detached before closing. If lwIP cannot queue
/// an orderly close, the control block is aborted. The operation is idempotent,
/// accepts `NULL`, and emits no connection callback.
///
/// - Parameter connection: Connection to close.
void rork_lwip_connection_close(rork_lwip_connection_t *connection);

/// Closes and releases an owned connection wrapper.
///
/// The pointer is invalid after this call and must not be used by queued work
/// or callbacks. Passing `NULL` is a no-op.
///
/// - Parameter connection: Owned connection wrapper to release.
void rork_lwip_connection_destroy(
    rork_lwip_connection_t *connection
);

#ifdef __cplusplus
}
#endif

#endif
