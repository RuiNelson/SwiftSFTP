/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2010-2020 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */
#pragma GCC visibility push(default)

#include <stddef.h>
#pragma GCC visibility pop
#include "internal/cryptlib.h"
#include <SwiftSFTP_OpenSSL/asn1.h>
#include <SwiftSFTP_OpenSSL/asn1t.h>
#include <SwiftSFTP_OpenSSL/objects.h>
#include <SwiftSFTP_OpenSSL/buffer.h>
#include <SwiftSFTP_OpenSSL/err.h>
#include <SwiftSFTP_OpenSSL/x509v3.h>
#include "asn1_local.h"

/*
 * General ASN1 structure recursive scanner: iterate through all fields
 * passing details to a callback.
 */

ASN1_SCTX *ASN1_SCTX_new(int (*scan_cb)(ASN1_SCTX *ctx))
{
    ASN1_SCTX *ret = OPENSSL_zalloc(sizeof(*ret));

    if (ret == NULL)
        return NULL;
    ret->scan_cb = scan_cb;
    return ret;
}

void ASN1_SCTX_free(ASN1_SCTX *p)
{
    OPENSSL_free(p);
}

const ASN1_ITEM *ASN1_SCTX_get_item(ASN1_SCTX *p)
{
    return p->it;
}

const ASN1_TEMPLATE *ASN1_SCTX_get_template(ASN1_SCTX *p)
{
    return p->tt;
}

unsigned long ASN1_SCTX_get_flags(ASN1_SCTX *p)
{
    return p->flags;
}

void ASN1_SCTX_set_app_data(ASN1_SCTX *p, void *data)
{
    p->app_data = data;
}

void *ASN1_SCTX_get_app_data(ASN1_SCTX *p)
{
    return p->app_data;
}
