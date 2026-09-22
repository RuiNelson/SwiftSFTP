#include "MEGACrypto.h"
#include <openssl/sha.h>

void mega_crypto_sha256(const unsigned char *bytes, size_t count, unsigned char *digest) {
    SHA256(bytes, count, digest);
}
