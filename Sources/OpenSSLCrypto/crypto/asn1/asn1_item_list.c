/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2000-2024 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

/* We need to use the low level ASN1 items until they are removed */
#define OPENSSL_SUPPRESS_DEPRECATED
#pragma GCC visibility push(default)

#include <stdio.h>
#pragma GCC visibility pop
#include "internal/cryptlib.h"
#include <SwiftSFTP_OpenSSL/asn1.h>
#include <SwiftSFTP_OpenSSL/asn1t.h>
#include <SwiftSFTP_OpenSSL/cms.h>
#include <SwiftSFTP_OpenSSL/dh.h>
#include <SwiftSFTP_OpenSSL/ocsp.h>
#include <SwiftSFTP_OpenSSL/pkcs7.h>
#include <SwiftSFTP_OpenSSL/pkcs12.h>
#include <SwiftSFTP_OpenSSL/rsa.h>
#include <SwiftSFTP_OpenSSL/x509v3.h>
#include <SwiftSFTP_OpenSSL/x509_acert.h>

#include "asn1_item_list.h"

const ASN1_ITEM *ASN1_ITEM_lookup(const char *name)
{
    size_t i;

    for (i = 0; i < OSSL_NELEM(asn1_item_list); i++) {
        const ASN1_ITEM *it = ASN1_ITEM_ptr(asn1_item_list[i]);

        if (strcmp(it->sname, name) == 0)
            return it;
    }
    return NULL;
}

const ASN1_ITEM *ASN1_ITEM_get(size_t i)
{
    if (i >= OSSL_NELEM(asn1_item_list))
        return NULL;
    return ASN1_ITEM_ptr(asn1_item_list[i]);
}
