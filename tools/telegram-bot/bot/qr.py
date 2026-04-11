"""QR code generation for conn_strings."""
from __future__ import annotations

import io

import qrcode
from qrcode.constants import ERROR_CORRECT_L


def generate_qr(text: str) -> io.BytesIO:
    """Render `text` as a QR-code PNG in memory.

    conn_strings are fairly long (~2KB base64), so we use low ECC and a
    small box size to keep the image compact. Auto version (fit=True).
    """
    qr = qrcode.QRCode(
        version=None,
        error_correction=ERROR_CORRECT_L,
        box_size=4,
        border=2,
    )
    qr.add_data(text)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return buf
