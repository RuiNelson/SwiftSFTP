/* SwiftSFTP extension: expose session->server_sign_algorithms.
 *
 * Upstream libssh2 receives RFC 8308 server-sig-algs via SSH_MSG_EXT_INFO and
 * stores it privately for RSA signature upgrades. There is no public getter.
 * Multi-key public-key selection needs that list, so this target-local helper
 * reads the field from the same sources we already compile.
 *
 * Do not edit vendor/libssh2 for this; keep the accessor outside the submodule.
 */

#include "libssh2_priv.h"

const char *libssh2_session_server_sign_algorithms(LIBSSH2_SESSION *session)
{
    if(!session)
        return NULL;
    return session->server_sign_algorithms;
}
