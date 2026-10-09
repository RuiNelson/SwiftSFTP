/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2001-2016 The OpenSSL Project Authors. All Rights Reserved.
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
#include <SwiftSFTP_OpenSSL/bio.h>
#include <SwiftSFTP_OpenSSL/evp.h>
#include <SwiftSFTP_OpenSSL/x509.h>
#include <SwiftSFTP_OpenSSL/pkcs7.h>
#include <SwiftSFTP_OpenSSL/pem.h>

IMPLEMENT_PEM_rw(X509, X509, PEM_STRING_X509, X509)
