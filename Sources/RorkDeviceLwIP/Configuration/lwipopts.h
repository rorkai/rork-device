#ifndef RORK_DEVICE_LWIP_OPTIONS_H
#define RORK_DEVICE_LWIP_OPTIONS_H

/// Uses lwIP's raw callback API without an operating-system abstraction layer.
///
/// RorkDevice supplies timer and random hooks directly and serializes every
/// protocol operation on one process-wide queue.
#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0

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
#define LWIP_IPV6_AUTOCONFIG 0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT 0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS 0
#define LWIP_IPV6_FRAG 0
#define LWIP_IPV6_REASS 0
#define LWIP_IPV6_MLD 0
#define LWIP_IPV6_DHCP6 0
#define LWIP_ND6_QUEUEING 0

/// Delegates dynamic storage to the host C allocator with 64-bit alignment.
///
/// This avoids a fixed global lwIP heap while preserving alignment required by
/// Swift-supported 64-bit Apple and Linux targets.
#define MEM_LIBC_MALLOC 1
#define MEMP_MEM_MALLOC 1
#define MEM_ALIGNMENT 8

/// Sizes protocol-control and packet pools for concurrent device services.
///
/// The values bound memory use while leaving room for multiple Remote Service
/// Discovery connections and packets in flight across active devices.
#define MEMP_NUM_TCP_PCB 64
#define MEMP_NUM_TCP_SEG 512
#define PBUF_POOL_SIZE 256
#define PBUF_POOL_BUFSIZE 1600

/// Tunes TCP for an IPv6 minimum-MTU userspace path.
///
/// A 1220-byte MSS reserves the 60 bytes required by the IPv6 and TCP headers
/// inside a 1280-byte packet. Larger send and receive windows reduce stalls
/// during application transfer without changing the on-wire packet limit.
#define TCP_MSS 1220
#define TCP_WND 65535
#define TCP_SND_BUF 49152
#define TCP_SND_QUEUELEN 256
#define TCP_QUEUE_OOSEQ 1
#define LWIP_TCP_SACK_OUT 1
#define LWIP_TCP_KEEPALIVE 1

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
