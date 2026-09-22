/* SwiftSFTP extension: expose libssh2's bcrypt_pbkdf.
 *
 * Passphrase-protected OpenSSH private keys derive their cipher key with
 * bcrypt_pbkdf, which OpenSSL does not provide. libssh2 already compiles the
 * OpenBSD implementation for its own key parsing but keeps it internal, so
 * this target-local helper forwards to it from the same sources we compile.
 *
 * Do not edit vendor/libssh2 for this; keep the accessor outside the submodule.
 */

#include "libssh2_priv.h"
#include "libssh2_swiftsftp.h"

int libssh2_swiftsftp_bcrypt_pbkdf(const char *pass, size_t passlen,
                                   const unsigned char *salt, size_t saltlen,
                                   unsigned char *key, size_t keylen,
                                   unsigned int rounds)
{
    return ssh2_bcrypt_pbkdf(pass, passlen, salt, saltlen, key, keylen,
                             rounds);
}
