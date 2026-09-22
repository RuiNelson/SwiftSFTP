#include "OtherCrypto.h"
#include <openssl/crypto.h>
#include <stddef.h>

static int calls;

int other_crypto_marker(void) { return OTHER_CRYPTO_MARKER; }
int other_crypto_calls(void) { return calls; }

// A strong same-named symbol, forced into the final image by the marker above.
void *EVP_PKEY_CTX_new_id(int identifier, void *engine) {
    (void)identifier;
    (void)engine;
    calls++;
    return NULL;
}
