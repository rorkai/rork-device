#ifndef RORK_DEVICE_LWIP_ARCH_CC_H
#define RORK_DEVICE_LWIP_ARCH_CC_H

#include <stdint.h>

#if defined(__APPLE__)
#include <sys/types.h>

/// Darwin exposes byte-order macros through `sys/types.h` after lwIP's
/// `arch.h` supplies macros with the same names.
///
/// Normalize the active definitions after both headers have participated so
/// later lwIP preprocessor checks have one unambiguous source of truth without
/// requiring unsafe compiler flags.
#undef BYTE_ORDER
#undef LITTLE_ENDIAN
#undef BIG_ENDIAN
#define LITTLE_ENDIAN 1234
#define BIG_ENDIAN 4321
#define BYTE_ORDER LITTLE_ENDIAN

#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS
#endif

/// Returns a process-local random value for lwIP protocol state.
///
/// The implementation uses the platform entropy API where available and is
/// invoked only from RorkDevice's serialized lwIP execution context.
uint32_t rork_lwip_random(void);

/// Connects lwIP's random hook to the package implementation.
#define LWIP_RAND() rork_lwip_random()

#endif
