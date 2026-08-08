#ifndef LIBSSH2_SWIFTSFTP_H
#define LIBSSH2_SWIFTSFTP_H

#include "libssh2.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Returns the server's RFC 8308 `server-sig-algs` list received during
 * handshake (`SSH_MSG_EXT_INFO`), or NULL when the server did not send it.
 *
 * The returned pointer is owned by the session and remains valid until the
 * session is freed or another handshake replaces the value.
 *
 * This is a SwiftSFTP extension over the vendored libssh2 sources; it is not
 * part of upstream libssh2.
 */
const char *libssh2_session_server_sign_algorithms(LIBSSH2_SESSION *session);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH2_SWIFTSFTP_H */
