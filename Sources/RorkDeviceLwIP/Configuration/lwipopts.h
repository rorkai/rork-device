#ifndef RORK_DEVICE_LWIP_OPTIONS_H
#define RORK_DEVICE_LWIP_OPTIONS_H

// Every documentation block in this file describes the whole group of
// options that follows it, up to the next banner or block.

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
/// would add state that the tunnel neither requires nor advertises. Router
/// advertisements do not exist inside the tunnel either, so the separate
/// RA-updated `mtu6` field would read zero — `LWIP_ND6_ALLOW_RA_UPDATES 0`
/// keeps the interface MTU authoritative, which is what clamps the effective
/// MSS on devices that granted a smaller tunnel MTU.
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
/// Swift-supported 64-bit Apple and Linux targets. Because storage is
/// malloc-backed, the TCP window and buffer limits below bound *demand-driven*
/// per-connection usage; nothing is reserved up front and idle connections
/// cost almost nothing.
#define MEM_LIBC_MALLOC 1
#define MEMP_MEM_MALLOC 1
#define MEM_ALIGNMENT 8

/// Sizes protocol-control and packet pools for concurrent device services.
///
/// `MEMP_NUM_TCP_PCB` is the process-wide concurrency cap and therefore also
/// the memory ceiling multiplier: 64 connections that all simultaneously fill
/// a one-megabyte send queue and a one-megabyte receive window would bound at
/// roughly 128 MB. That worst case requires every connection to stall with
/// full buffers at once; in practice a tunnel process carries a handful of
/// service streams with one bulk transfer in flight, keeping usage in the
/// tens of megabytes at peak — an accepted host-side budget (these helpers
/// run on the Mac, not the device).
#define MEMP_NUM_TCP_PCB 64
#define MEMP_NUM_TCP_SEG 512
#define PBUF_POOL_SIZE 256
#define PBUF_POOL_BUFSIZE 1600

// ============================================================================
// MARK: TCP throughput profile
// ============================================================================

/// Tunes TCP for the multi-kilobyte MTU CoreDevice grants on modern iOS.
///
/// A 15,940-byte MSS reserves the 60 bytes required by the IPv6 and TCP
/// headers inside the largest tunnel MTU worth requesting (16,000). Devices
/// that grant less shrink both the sent and the advertised segment size at
/// runtime: `TCP_CALCULATE_EFF_SEND_MSS` clamps them to the interface MTU
/// carried by the granted tunnel configuration.
///
/// RFC 7323 window scaling lets the one-megabyte windows below survive the
/// TCP header's 16-bit window field (65,535 << 4). Large windows keep an IPA
/// staging transfer from stalling on window exhaustion at tunnel latencies.
/// `TCP_SNDLOWAT` exists only to satisfy lwIP's sanity check: it feeds the
/// sockets select() API, which this build compiles out, and its default
/// derives from `TCP_SND_BUF`, overflowing u16 with jumbo segments.
#define TCP_MSS 15940
#define LWIP_WND_SCALE 1
#define TCP_RCV_SCALE 4
#define TCP_WND 1048560
#define TCP_SND_BUF 1048576
#define TCP_SND_QUEUELEN 512
#define TCP_SNDLOWAT (0xffff - (4 * TCP_MSS) - 1)
#define TCP_QUEUE_OOSEQ 1
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
