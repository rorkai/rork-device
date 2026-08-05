#ifndef RORK_DEVICE_PLATFORM_H
#define RORK_DEVICE_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Writes bytes through an owner-only temporary file and atomically publishes
/// the destination.
///
/// Returns zero on success, one when a non-replacing destination already
/// exists, and two on failure. Failures store the Win32 code in `error_code`.
///
/// - Parameters:
///   - destination_path: Null-terminated UTF-16 path for the published file.
///   - temporary_path: Null-terminated UTF-16 path for the owner-only sibling.
///   - bytes: Bytes to write. This may be null only when `length` is zero.
///   - length: Number of bytes to write.
///   - replace_existing: Nonzero permits replacing an existing destination.
///   - error_code: Receives a platform error code on failure.
int32_t rork_windows_write_file_atomically(
    const uint16_t *destination_path,
    const uint16_t *temporary_path,
    const uint8_t *bytes,
    size_t length,
    int32_t replace_existing,
    uint32_t *error_code
);

/// Reports whether a file grants access only to its owning Windows user.
///
/// Returns zero when the query completes and stores the Boolean result in
/// `has_protected_access`. Failures store the Win32 code in `error_code`.
///
/// - Parameters:
///   - path: Null-terminated UTF-16 path to inspect.
///   - has_protected_access: Receives one when the current user has sole access.
///   - error_code: Receives a platform error code on failure.
int32_t rork_windows_file_has_current_user_only_access(
    const uint16_t *path,
    int32_t *has_protected_access,
    uint32_t *error_code
);

#ifdef __cplusplus
}
#endif

#endif
