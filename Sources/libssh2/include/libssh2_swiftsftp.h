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

/**
 * Derives `keylen` bytes into `key` with OpenSSH's bcrypt_pbkdf, the KDF used
 * by passphrase-protected OpenSSH private keys (`kdfname` "bcrypt").
 *
 * Returns 0 on success, or -1 when an argument is out of range: empty
 * passphrase, salt or key, zero rounds, or `keylen` above 1024 bytes.
 *
 * This is a SwiftSFTP extension over the vendored libssh2 sources; it is not
 * part of upstream libssh2.
 */
int libssh2_swiftsftp_bcrypt_pbkdf(const char *pass, size_t passlen,
                                   const unsigned char *salt, size_t saltlen,
                                   unsigned char *key, size_t keylen,
                                   unsigned int rounds);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH2_SWIFTSFTP_H */
