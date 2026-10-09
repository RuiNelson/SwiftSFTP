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
#pragma GCC visibility push(default)

#include <stdio.h>
#pragma GCC visibility pop
#include "internal/cryptlib.h"
#include <SwiftSFTP_OpenSSL/objects.h>
#include <SwiftSFTP_OpenSSL/bn.h>
#include <SwiftSFTP_OpenSSL/x509v3.h>
#include <SwiftSFTP_OpenSSL/ts.h>
#include "ts_local.h"

int TS_REQ_print_bio(BIO *bio, TS_REQ *a)
{
    int v;
    ASN1_OBJECT *policy_id;

    if (a == NULL)
        return 0;

    v = TS_REQ_get_version(a);
    BIO_printf(bio, "Version: %d\n", v);

    TS_MSG_IMPRINT_print_bio(bio, a->msg_imprint);

    BIO_printf(bio, "Policy OID: ");
    policy_id = TS_REQ_get_policy_id(a);
    if (policy_id == NULL)
        BIO_printf(bio, "unspecified\n");
    else
        TS_OBJ_print_bio(bio, policy_id);

    BIO_printf(bio, "Nonce: ");
    if (a->nonce == NULL)
        BIO_printf(bio, "unspecified");
    else
        TS_ASN1_INTEGER_print_bio(bio, a->nonce);
    BIO_write(bio, "\n", 1);

    BIO_printf(bio, "Certificate required: %s\n",
        a->cert_req ? "yes" : "no");

    TS_ext_print_bio(bio, a->extensions);

    return 1;
}
