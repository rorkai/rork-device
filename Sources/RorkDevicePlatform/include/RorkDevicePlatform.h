#ifndef RORK_DEVICE_PLATFORM_H
#define RORK_DEVICE_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t rork_windows_write_file_atomically(
    const uint16_t *destination_path,
    const uint16_t *temporary_path,
    const uint8_t *bytes,
    size_t length,
    int32_t replace_existing,
    uint32_t *error_code
);

int32_t rork_windows_file_has_current_user_only_access(
    const uint16_t *path,
    int32_t *has_protected_access,
    uint32_t *error_code
);

#ifdef __cplusplus
}
#endif

#endif
