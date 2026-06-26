"""Blowfish ECB encryption/decryption for Pandora's JSON RPC.

Pandora encrypts request bodies (everything except partnerLogin) and most response
fields with Blowfish in ECB mode, then hex-encodes the result. We use the
`cryptography` library's Blowfish (now in the `decrepit` module — Blowfish has been
deprecated by modern standards, but Pandora still uses it).
"""

from __future__ import annotations

from cryptography.hazmat.decrepit.ciphers.algorithms import Blowfish
from cryptography.hazmat.primitives.ciphers import Cipher, modes

_BLOCK = 8


def _cipher(key: bytes) -> Cipher:
    return Cipher(Blowfish(key), modes.ECB())


def encrypt(plaintext: str, key: bytes) -> str:
    """Encrypt a JSON body string with Blowfish/ECB and return hex."""
    data = plaintext.encode("utf-8")
    # NUL-pad to block boundary (this is what Pandora's client does — not PKCS7).
    pad = (-len(data)) % _BLOCK
    data += b"\x00" * pad
    enc = _cipher(key).encryptor()
    ct = enc.update(data) + enc.finalize()
    return ct.hex()


def decrypt(hex_ct: str, key: bytes) -> bytes:
    """Decrypt a hex-encoded Blowfish/ECB blob. Returns raw plaintext bytes,
    including whatever trailing padding Pandora used (NUL or PKCS-style).
    Callers are responsible for trimming."""
    ct = bytes.fromhex(hex_ct)
    dec = _cipher(key).decryptor()
    return dec.update(ct) + dec.finalize()


def decrypt_sync_time(encrypted_hex: str, key: bytes) -> int:
    """Pandora's syncTime is hex-encoded, Blowfish-encrypted, with the first 4
    plaintext bytes being random garbage and trailing PKCS-style padding bytes
    (e.g. \\x02\\x02). Pull out the ASCII digits in between."""
    raw = decrypt(encrypted_hex, key)
    digits = bytes(b for b in raw[4:] if 0x30 <= b <= 0x39)
    return int(digits.decode("ascii"))
