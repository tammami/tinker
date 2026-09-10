// CTinkerBcrypt — OpenBSD's bcrypt_pbkdf, the key derivation OpenSSH uses for
// passphrase-protected private keys. Vendored (blf.c, blf.h, bcrypt_pbkdf.c) from OpenBSD
// by way of Citadel's copy; see DECISIONS.md ADR-0039. Licences are in the sources.
#ifndef CTINKER_BCRYPT_H
#define CTINKER_BCRYPT_H

#include <stddef.h>
#include <stdint.h>

/// Derives `keylen` bytes from a passphrase and salt with `rounds` rounds of bcrypt.
/// Returns 0 on success and -1 on a bad argument, in which case `key` holds random bytes.
int tinker_bcrypt_pbkdf(const uint8_t *pass, size_t passlen,
                        const uint8_t *salt, size_t saltlen,
                        uint8_t *key, size_t keylen, unsigned int rounds);

#endif
