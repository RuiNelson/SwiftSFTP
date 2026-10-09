/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2002-2020 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#include <SwiftSFTP_OpenSSL/opensslv.h>
#include <SwiftSFTP_OpenSSL/aes.h>
#include "aes_local.h"

#ifndef OPENSSL_NO_DEPRECATED_3_0
const char *AES_options(void)
{
#ifdef FULL_UNROLL
    return "aes(full)";
#else
    return "aes(partial)";
#endif
}
#endif
