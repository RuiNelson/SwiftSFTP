#ifndef OSSL_CRYPTO_EVP_B64_SCALAR_H
#define OSSL_CRYPTO_EVP_B64_SCALAR_H
#include <SwiftSFTP_OpenSSL/evp.h>
#pragma GCC visibility push(default)
#include <stddef.h>
#pragma GCC visibility pop

size_t evp_encodeblock_int(EVP_ENCODE_CTX *ctx, unsigned char *t,
    const unsigned char *f, int dlen, int *wrap_cnt);

#endif
