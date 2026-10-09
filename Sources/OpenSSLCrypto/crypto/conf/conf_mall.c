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
#pragma GCC visibility push(default)

#include <stdio.h>
#pragma GCC visibility pop
#include <SwiftSFTP_OpenSSL/crypto.h>
#include "internal/cryptlib.h"
#include <SwiftSFTP_OpenSSL/conf.h>
#include <SwiftSFTP_OpenSSL/x509.h>
#include <SwiftSFTP_OpenSSL/asn1.h>
#include "internal/provider.h"
#include "crypto/rand.h"
#include "conf_local.h"

/* Load all OpenSSL builtin modules */

void OPENSSL_load_builtin_modules(void)
{
    /* Add builtin modules here */
    ASN1_add_oid_module();
    ASN1_add_stable_module();
    EVP_add_alg_module();
    ossl_config_add_ssl_module();
    ossl_provider_add_conf_module();
    ossl_random_add_conf_module();
}
