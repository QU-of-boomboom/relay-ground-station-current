// SPDX-License-Identifier: GPL-2.0-or-later
/* Limited regulatory-database verification backport for the FMQL 5.4.52 image.
 * Verification sequence derived from Linux certs/system_keyring.c:
 * Copyright (C) 2012 Red Hat, Inc. Written by David Howells.
 *
 * The running image has the PKCS#7 primitives but lacks the wrapper export.
 * Only cfg80211's explicit regulatory keyring use is supported. NULL and the
 * system/secondary/platform keyring selectors are rejected, never trusted.
 * No successful result is returned without cryptographic and trust checks.
 */
#include <linux/module.h>
#include <linux/err.h>
#include <linux/verification.h>
#include <crypto/pkcs7.h>
#include "pkcs7_parser.h"

/* Private-ABI experimental backport from crypto/asymmetric_keys/pkcs7_verify.c.
 * Requires the matching kernel parser layout; not a generic distribution module.
 */
static int relay_supply_detached_data(struct pkcs7_message *message,
                                     const void *data, size_t len)
{
    if (message->data)
        return -EINVAL;
    message->data = data;
    message->data_len = len;
    return 0;
}

int verify_pkcs7_signature(const void *data, size_t len,
                          const void *raw_pkcs7, size_t pkcs7_len,
                          struct key *trusted_keys,
                          enum key_being_used_for usage,
                          int (*view_content)(void *, const void *, size_t, size_t),
                          void *ctx)
{
    struct pkcs7_message *message;
    int result;

    if ((unsigned long)trusted_keys <= 2 || IS_ERR(trusted_keys) ||
        usage != VERIFYING_UNSPECIFIED_SIGNATURE || view_content || ctx ||
        !data || !len || !raw_pkcs7 || !pkcs7_len)
        return -EINVAL;
    message = pkcs7_parse_message(raw_pkcs7, pkcs7_len);
    if (IS_ERR(message))
        return PTR_ERR(message);
    result = relay_supply_detached_data(message, data, len);
    if (result < 0)
        goto out;
    result = pkcs7_verify(message, usage);
    if (result < 0)
        goto out;
    result = pkcs7_validate_trust(message, trusted_keys);
out:
    pkcs7_free_message(message);
    return result;
}
EXPORT_SYMBOL_GPL(verify_pkcs7_signature);

static int __init relay_verify_init(void)
{
    /* Fail-closed argument path; signed/tampered database tests are separate. */
    if (verify_pkcs7_signature(NULL, 0, NULL, 0, NULL,
                              VERIFYING_UNSPECIFIED_SIGNATURE, NULL, NULL) != -EINVAL)
        return -EINVAL;
    pr_info("relay_regdb_verify: explicit regulatory keyring only; signature verification retained\n");
    return 0;
}
static void __exit relay_verify_exit(void) { }
module_init(relay_verify_init);
module_exit(relay_verify_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("FMQL regulatory PKCS7 wrapper, explicit keyring only");
