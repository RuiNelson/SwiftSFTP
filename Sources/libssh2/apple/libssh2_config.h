/* Apple-only target configuration, reached through libssh2_setup.h. */
#ifndef SWIFTSFTP_LIBSSH2_APPLE_CONFIG_H
#define SWIFTSFTP_LIBSSH2_APPLE_CONFIG_H

/* Xcode's shared include/ directory can contain another SDK's openssl/ headers.
 * Preload the pinned backend with framework-qualified includes; its original
 * include guard prevents libssh2's later crypto.h include from selecting those
 * foreign headers. All backend definitions remain generated from the submodule.
 */
#include "openssl_backend.h"

#endif
