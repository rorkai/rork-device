#include "RorkDevicePlatform.h"

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <accctrl.h>
#include <aclapi.h>

typedef struct rork_current_user_security {
    HANDLE token;
    PTOKEN_USER token_user;
    PACL acl;
    PSECURITY_DESCRIPTOR descriptor;
    SECURITY_ATTRIBUTES attributes;
} rork_current_user_security_t;

static void rork_release_current_user_security(
    rork_current_user_security_t *security
) {
    if (security->descriptor != NULL) {
        LocalFree(security->descriptor);
    }
    if (security->acl != NULL) {
        LocalFree(security->acl);
    }
    if (security->token_user != NULL) {
        LocalFree(security->token_user);
    }
    if (security->token != NULL) {
        CloseHandle(security->token);
    }
}

static int rork_make_current_user_security(
    rork_current_user_security_t *security,
    uint32_t *error_code
) {
    ZeroMemory(security, sizeof(*security));
    if (
        !OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_QUERY,
            &security->token
        )
    ) {
        *error_code = GetLastError();
        return 0;
    }

    DWORD token_user_length = 0;
    GetTokenInformation(
        security->token,
        TokenUser,
        NULL,
        0,
        &token_user_length
    );
    if (
        token_user_length == 0 ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER
    ) {
        *error_code = GetLastError();
        return 0;
    }

    security->token_user = LocalAlloc(LPTR, token_user_length);
    if (security->token_user == NULL) {
        *error_code = ERROR_NOT_ENOUGH_MEMORY;
        return 0;
    }
    if (
        !GetTokenInformation(
            security->token,
            TokenUser,
            security->token_user,
            token_user_length,
            &token_user_length
        )
    ) {
        *error_code = GetLastError();
        return 0;
    }

    EXPLICIT_ACCESS_W access;
    ZeroMemory(&access, sizeof(access));
    access.grfAccessPermissions = FILE_ALL_ACCESS;
    access.grfAccessMode = SET_ACCESS;
    access.grfInheritance = NO_INHERITANCE;
    access.Trustee.MultipleTrusteeOperation = NO_MULTIPLE_TRUSTEE;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_USER;
    access.Trustee.ptstrName =
        (LPWSTR)security->token_user->User.Sid;

    DWORD acl_result = SetEntriesInAclW(
        1,
        &access,
        NULL,
        &security->acl
    );
    if (acl_result != ERROR_SUCCESS) {
        *error_code = acl_result;
        return 0;
    }

    security->descriptor = LocalAlloc(
        LPTR,
        SECURITY_DESCRIPTOR_MIN_LENGTH
    );
    if (security->descriptor == NULL) {
        *error_code = ERROR_NOT_ENOUGH_MEMORY;
        return 0;
    }
    if (
        !InitializeSecurityDescriptor(
            security->descriptor,
            SECURITY_DESCRIPTOR_REVISION
        ) ||
        !SetSecurityDescriptorOwner(
            security->descriptor,
            security->token_user->User.Sid,
            FALSE
        ) ||
        !SetSecurityDescriptorDacl(
            security->descriptor,
            TRUE,
            security->acl,
            FALSE
        ) ||
        !SetSecurityDescriptorControl(
            security->descriptor,
            SE_DACL_PROTECTED,
            SE_DACL_PROTECTED
        )
    ) {
        *error_code = GetLastError();
        return 0;
    }

    security->attributes.nLength = sizeof(security->attributes);
    security->attributes.lpSecurityDescriptor = security->descriptor;
    security->attributes.bInheritHandle = FALSE;
    return 1;
}

static int rork_write_all(
    HANDLE file,
    const uint8_t *bytes,
    size_t length,
    uint32_t *error_code
) {
    size_t offset = 0;
    while (offset < length) {
        size_t remaining = length - offset;
        DWORD requested = remaining > UINT32_MAX
            ? UINT32_MAX
            : (DWORD)remaining;
        DWORD written = 0;
        if (
            !WriteFile(
                file,
                bytes + offset,
                requested,
                &written,
                NULL
            )
        ) {
            *error_code = GetLastError();
            return 0;
        }
        if (written == 0) {
            *error_code = ERROR_WRITE_FAULT;
            return 0;
        }
        offset += written;
    }
    return 1;
}

int32_t rork_windows_write_file_atomically(
    const uint16_t *destination_path,
    const uint16_t *temporary_path,
    const uint8_t *bytes,
    size_t length,
    int32_t replace_existing,
    uint32_t *error_code
) {
    if (
        destination_path == NULL ||
        temporary_path == NULL ||
        (bytes == NULL && length != 0) ||
        error_code == NULL
    ) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 2;
    }

    rork_current_user_security_t security;
    if (!rork_make_current_user_security(&security, error_code)) {
        rork_release_current_user_security(&security);
        return 2;
    }

    HANDLE file = CreateFileW(
        (LPCWSTR)temporary_path,
        GENERIC_WRITE,
        0,
        &security.attributes,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH,
        NULL
    );
    uint32_t create_error = file == INVALID_HANDLE_VALUE
        ? GetLastError()
        : ERROR_SUCCESS;
    rork_release_current_user_security(&security);
    if (file == INVALID_HANDLE_VALUE) {
        *error_code = create_error;
        return 2;
    }

    int wrote_file = rork_write_all(
        file,
        bytes,
        length,
        error_code
    );
    if (wrote_file && !FlushFileBuffers(file)) {
        *error_code = GetLastError();
        wrote_file = 0;
    }
    if (!CloseHandle(file) && wrote_file) {
        *error_code = GetLastError();
        wrote_file = 0;
    }
    if (!wrote_file) {
        uint32_t write_error = *error_code;
        DeleteFileW((LPCWSTR)temporary_path);
        *error_code = write_error;
        return 2;
    }

    DWORD move_flags = MOVEFILE_WRITE_THROUGH;
    if (replace_existing) {
        move_flags |= MOVEFILE_REPLACE_EXISTING;
    }
    if (
        MoveFileExW(
            (LPCWSTR)temporary_path,
            (LPCWSTR)destination_path,
            move_flags
        )
    ) {
        *error_code = ERROR_SUCCESS;
        return 0;
    }

    uint32_t move_error = GetLastError();
    DeleteFileW((LPCWSTR)temporary_path);
    *error_code = move_error;
    if (
        !replace_existing &&
        (
            move_error == ERROR_ALREADY_EXISTS ||
            move_error == ERROR_FILE_EXISTS
        )
    ) {
        return 1;
    }
    return 2;
}

int32_t rork_windows_file_has_current_user_only_access(
    const uint16_t *path,
    int32_t *has_protected_access,
    uint32_t *error_code
) {
    if (
        path == NULL ||
        has_protected_access == NULL ||
        error_code == NULL
    ) {
        if (error_code != NULL) {
            *error_code = ERROR_INVALID_PARAMETER;
        }
        return 2;
    }

    rork_current_user_security_t security;
    if (!rork_make_current_user_security(&security, error_code)) {
        rork_release_current_user_security(&security);
        return 2;
    }

    PSID owner = NULL;
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    DWORD security_result = GetNamedSecurityInfoW(
        (LPWSTR)path,
        SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner,
        NULL,
        &dacl,
        NULL,
        &descriptor
    );
    if (security_result != ERROR_SUCCESS) {
        rork_release_current_user_security(&security);
        *error_code = security_result;
        return 2;
    }

    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    ACL_SIZE_INFORMATION acl_information;
    ZeroMemory(&acl_information, sizeof(acl_information));
    int protected_access =
        owner != NULL &&
        EqualSid(owner, security.token_user->User.Sid) &&
        GetSecurityDescriptorControl(
            descriptor,
            &control,
            &revision
        ) &&
        (control & SE_DACL_PROTECTED) != 0 &&
        dacl != NULL &&
        GetAclInformation(
            dacl,
            &acl_information,
            sizeof(acl_information),
            AclSizeInformation
        );

    int found_current_user = 0;
    for (
        DWORD index = 0;
        protected_access && index < acl_information.AceCount;
        index += 1
    ) {
        void *raw_ace = NULL;
        if (!GetAce(dacl, index, &raw_ace)) {
            protected_access = 0;
            break;
        }
        ACE_HEADER *header = raw_ace;
        if (
            header->AceType != ACCESS_ALLOWED_ACE_TYPE ||
            (header->AceFlags & INHERITED_ACE) != 0
        ) {
            protected_access = 0;
            break;
        }
        ACCESS_ALLOWED_ACE *ace = raw_ace;
        PSID sid = &ace->SidStart;
        if (
            !EqualSid(sid, security.token_user->User.Sid) ||
            (ace->Mask & FILE_ALL_ACCESS) != FILE_ALL_ACCESS
        ) {
            protected_access = 0;
            break;
        }
        found_current_user = 1;
    }

    LocalFree(descriptor);
    rork_release_current_user_security(&security);
    *has_protected_access =
        protected_access && found_current_user ? 1 : 0;
    *error_code = ERROR_SUCCESS;
    return 0;
}

#else

#include <errno.h>

int32_t rork_windows_write_file_atomically(
    const uint16_t *destination_path,
    const uint16_t *temporary_path,
    const uint8_t *bytes,
    size_t length,
    int32_t replace_existing,
    uint32_t *error_code
) {
    (void)destination_path;
    (void)temporary_path;
    (void)bytes;
    (void)length;
    (void)replace_existing;
    if (error_code != NULL) {
        *error_code = ENOTSUP;
    }
    return 2;
}

int32_t rork_windows_file_has_current_user_only_access(
    const uint16_t *path,
    int32_t *has_protected_access,
    uint32_t *error_code
) {
    (void)path;
    if (has_protected_access != NULL) {
        *has_protected_access = 0;
    }
    if (error_code != NULL) {
        *error_code = ENOTSUP;
    }
    return 2;
}

#endif
