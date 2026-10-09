/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2022-2025 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */
#pragma GCC visibility push(default)

#include <string.h> /* for memcpy() */
#pragma GCC visibility pop
#include <SwiftSFTP_OpenSSL/core_names.h>
#include <SwiftSFTP_OpenSSL/crypto.h>
#include "prov/eckem.h"

typedef struct {
    unsigned int id;
    const char *mode;
} KEM_MODE;

static const KEM_MODE eckem_modename_id_map[] = {
    { KEM_MODE_DHKEM, OSSL_KEM_PARAM_OPERATION_DHKEM },
    { 0, NULL }
};

int ossl_eckem_modename2id(const char *name)
{
    size_t i;

    if (name == NULL)
        return KEM_MODE_UNDEFINED;

    for (i = 0; eckem_modename_id_map[i].mode != NULL; ++i) {
        if (OPENSSL_strcasecmp(name, eckem_modename_id_map[i].mode) == 0)
            return eckem_modename_id_map[i].id;
    }
    return KEM_MODE_UNDEFINED;
}
