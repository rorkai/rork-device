#ifndef RORK_DEVICE_LWIP_OPTIONS_H
#define RORK_DEVICE_LWIP_OPTIONS_H

// ============================================================================
// MARK: Execution model
// ============================================================================

/// Uses lwIP's raw callback API without an operating-system abstraction layer.
///
/// RorkDevice supplies timer and random hooks directly and serializes every
/// protocol operation on one process-wide queue.
#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0

// ============================================================================
// MARK: Protocol surface
// ============================================================================

/// Builds only the IPv6 and TCP protocol surface required by CoreDevice.
///
/// Socket, netconn, DNS, UDP, and raw APIs remain disabled so the private C
/// target exposes no unused network stack behavior.
#define LWIP_IPV4 0
#define LWIP_IPV6 1
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_RAW 0
#define LWIP_DNS 0
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_NETIF_API 0

/// Allows one interface per active CoreDevice userspace network.
///
/// TCP control blocks are explicitly bound to their owning interface, so
/// multiple devices can use overlapping userspace address ranges safely.
#define LWIP_SINGLE_NETIF 0
#define LWIP_NETIF_LOOPBACK 0
#define LWIP_HAVE_LOOPIF 0

/// Disables autonomous IPv6 configuration and packet transformations.
///
/// CoreDevice provides fixed point-to-point addresses and complete packets.
/// Fragmentation, reassembly, multicast discovery, DHCP, and neighbor queueing
/// would add state that the tunnel neither requires nor advertises.
///
/// There are no router advertisements inside the tunnel. With RA updates
/// enabled, lwIP would track the IPv6 MTU in a separate field that nothing
/// ever sets, and the effective-MSS clamp would read it as zero. Keeping RA
/// updates off makes the interface MTU the single source of truth.
#define LWIP_IPV6_AUTOCONFIG 0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT 0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS 0
#define LWIP_IPV6_FRAG 0
#define LWIP_IPV6_REASS 0
#define LWIP_IPV6_MLD 0
#define LWIP_IPV6_DHCP6 0
#define LWIP_ND6_QUEUEING 0
#define LWIP_ND6_ALLOW_RA_UPDATES 0

// ============================================================================
// MARK: Memory model
// ============================================================================

/// Delegates dynamic storage to the host C allocator with 64-bit alignment.
///
/// This avoids a fixed global lwIP heap while preserving alignment required by
/// Swift-supported 64-bit Apple and Linux targets. Buffers are allocated on
/// demand and freed when drained, so the TCP limits below are ceilings rather
/// than reservations.
#define MEM_LIBC_MALLOC 1
#define MEMP_MEM_MALLOC 1
#define MEM_ALIGNMENT 8

/// Sizes protocol-control and packet pools for concurrent device services.
///
/// The PCB cap is also the memory ceiling. If all 64 connections filled their
/// megabyte buffers in both directions at once, the process would use about
/// 128 MB of host memory. Real tunnel processes run a few streams with one
/// bulk transfer in flight.
#define MEMP_NUM_TCP_PCB 64
#define MEMP_NUM_TCP_SEG 512
#define PBUF_POOL_SIZE 256
#define PBUF_POOL_BUFSIZE 1600

// ============================================================================
// MARK: TCP throughput profile
// ============================================================================

/// Tunes TCP for the multi-kilobyte MTU that CoreDevice grants on modern iOS.
///
/// The MSS reserves 60 bytes of IPv6 and TCP headers inside a 16,000-byte
/// packet, the largest tunnel MTU worth requesting. When a device grants a
/// smaller MTU, lwIP shrinks both the sent and the advertised segment size to
/// fit it. That clamp is `TCP_CALCULATE_EFF_SEND_MSS`, which is on by default.
///
/// The window and send-buffer values are one megabyte so that a large app
/// transfer does not stall waiting for window updates. A 16-bit TCP header
/// field cannot carry such a window, which is what RFC 7323 window scaling
/// solves. `TCP_WND` is 65,535 shifted by the scale of 4.
///
/// `TCP_SNDLOWAT` only feeds the sockets select() API, which this build
/// compiles out. It is defined because lwIP's sanity check requires a value
/// four segments below the u16 ceiling, and the default derived from
/// `TCP_SND_BUF` overflows with jumbo segments.
#define TCP_MSS 15940
#define TCP_WND 1048560
#define TCP_SND_BUF 1048576
#define TCP_SND_QUEUELEN 512
#define TCP_SNDLOWAT (0xffff - (4 * TCP_MSS) - 1)
#define TCP_RCV_SCALE 4
#define TCP_QUEUE_OOSEQ 1
#define LWIP_WND_SCALE 1
#define LWIP_TCP_SACK_OUT 1
#define LWIP_TCP_KEEPALIVE 1

// ============================================================================
// MARK: Diagnostics
// ============================================================================

/// Keeps protocol counters available for tunnel data-plane diagnostics.
///
/// TCP and IPv6 counters use 32-bit storage so long transfers do not wrap,
/// and MIB2 counters add the retransmission visibility that the base protocol
/// stats lack. Counter groups that the statistics API never exposes stay
/// disabled, as does the statistics display; RorkDevice reads counters
/// programmatically and reports them through its own logging surfaces.
#define LWIP_STATS 1
#define LWIP_STATS_LARGE 1
#define LWIP_STATS_DISPLAY 0
#define MIB2_STATS 1
#define LINK_STATS 0
#define ND6_STATS 0
#define ICMP6_STATS 0
#define LWIP_DEBUG 0

#endif
