/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2006-2016 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#include <SwiftSFTP_OpenSSL/asn1.h>
#include <SwiftSFTP_OpenSSL/pkcs7.h>
#include <SwiftSFTP_OpenSSL/bio.h>

/* Streaming encode support for PKCS#7 */

BIO *BIO_new_PKCS7(BIO *out, PKCS7 *p7)
{
    return BIO_new_NDEF(out, (ASN1_VALUE *)p7, ASN1_ITEM_rptr(PKCS7));
}
