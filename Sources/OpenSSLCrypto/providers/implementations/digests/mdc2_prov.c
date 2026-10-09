/* Prepared by Scripts/generate-openssl-sources.py. */
#pragma GCC visibility push(hidden)
#define STATIC_LEGACY
/*
 * Copyright 2019-2021 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

/*
 * MDC2 low level APIs are deprecated for public use, but still ok for
 * internal use.
 */
#include "internal/deprecated.h"
#pragma GCC visibility push(default)

#include <string.h>
#pragma GCC visibility pop
#include <SwiftSFTP_OpenSSL/crypto.h>
#include <SwiftSFTP_OpenSSL/params.h>
#include <SwiftSFTP_OpenSSL/mdc2.h>
#include <SwiftSFTP_OpenSSL/core_names.h>
#include <SwiftSFTP_OpenSSL/err.h>
#include <SwiftSFTP_OpenSSL/proverr.h>
#include <internal/common.h>
#include "prov/digestcommon.h"
#include "prov/implementations.h"
#include "providers/implementations/digests/mdc2_prov.inc"

static OSSL_FUNC_digest_set_ctx_params_fn mdc2_set_ctx_params;
static OSSL_FUNC_digest_settable_ctx_params_fn mdc2_settable_ctx_params;

static const OSSL_PARAM *mdc2_settable_ctx_params(ossl_unused void *ctx,
    ossl_unused void *provctx)
{
    return mdc2_set_ctx_params_list;
}

static int mdc2_set_ctx_params(void *vctx, const OSSL_PARAM params[])
{
    struct mdc2_set_ctx_params_st p;
    MDC2_CTX *ctx = (MDC2_CTX *)vctx;

    if (ctx == NULL || !mdc2_set_ctx_params_decoder(params, &p))
        return 0;

    if (p.pad != NULL && !OSSL_PARAM_get_uint(p.pad, &ctx->pad_type)) {
        ERR_raise(ERR_LIB_PROV, PROV_R_FAILED_TO_GET_PARAMETER);
        return 0;
    }
    return 1;
}

/* ossl_mdc2_functions */
IMPLEMENT_digest_functions_with_settable_ctx(
    mdc2, MDC2_CTX, MDC2_BLOCK, MDC2_DIGEST_LENGTH, 0,
    MDC2_Init, MDC2_Update, MDC2_Final,
    mdc2_settable_ctx_params, mdc2_set_ctx_params)
