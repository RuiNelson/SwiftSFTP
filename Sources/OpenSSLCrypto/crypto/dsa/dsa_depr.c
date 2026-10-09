/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2002-2021 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

/*
 * This file contains deprecated function(s) that are now wrappers to the new
 * version(s).
 */

/*
 * DSA low level APIs are deprecated for public use, but still ok for
 * internal use.
 */
#include "internal/deprecated.h"

#include <SwiftSFTP_OpenSSL/opensslconf.h>
#pragma GCC visibility push(default)

#include <stdio.h>
#pragma GCC visibility pop
#pragma GCC visibility push(default)
#include <time.h>
#pragma GCC visibility pop
#include "internal/cryptlib.h"
#include <SwiftSFTP_OpenSSL/evp.h>
#include <SwiftSFTP_OpenSSL/bn.h>
#include <SwiftSFTP_OpenSSL/dsa.h>
#include <SwiftSFTP_OpenSSL/sha.h>

DSA *DSA_generate_parameters(int bits,
    unsigned char *seed_in, int seed_len,
    int *counter_ret, unsigned long *h_ret,
    void (*callback)(int, int, void *),
    void *cb_arg)
{
    BN_GENCB *cb;
    DSA *ret;

    if ((ret = DSA_new()) == NULL)
        return NULL;
    cb = BN_GENCB_new();
    if (cb == NULL)
        goto err;

    BN_GENCB_set_old(cb, callback, cb_arg);

    if (DSA_generate_parameters_ex(ret, bits, seed_in, seed_len,
            counter_ret, h_ret, cb)) {
        BN_GENCB_free(cb);
        return ret;
    }
    BN_GENCB_free(cb);
err:
    DSA_free(ret);
    return NULL;
}
