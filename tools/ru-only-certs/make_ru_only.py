# Свой корень с Name Constraints (.ru/.рф/.su) + переподпись Russian Trusted Sub CA.
# Закрытый ключ корня живёт только в памяти и на диск не пишется.
#
# Перегенерация (если Минцифры сменит Sub CA — тогда обнови SUB_SHA256):
#   openssl s_client -connect online.sberbank.ru:443 -servername online.sberbank.ru -showcerts </dev/null > /tmp/chain.raw
#   python3 make_ru_only.py /tmp/chain.raw .
# Затем скопировать ru-only-* в apps/ios и apps/android (см. ADR 0023). Новый корень = пользователи переустанавливают.
import sys, re, datetime, plistlib, uuid, ipaddress, subprocess, tempfile
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

raw, out = sys.argv[1], sys.argv[2]
SUB_SHA256 = "2155785036c900dbb5f1bb2a1569c80c"  # префикс, совпал на sberbank.ru и vtb.ru

pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", open(raw).read(), re.S)
certs = [x509.load_pem_x509_certificate(p.encode()) for p in pems]
leaf, sub, mroot = certs[0], certs[1], certs[2]
assert sub.fingerprint(hashes.SHA256()).hex().startswith(SUB_SHA256)
sub.verify_directly_issued_by(mroot)  # Sub CA действительно подписан корнем Минцифры
leaf.verify_directly_issued_by(sub)


def constraints(zones):
    return x509.NameConstraints(
        permitted_subtrees=[x509.DNSName(z) for z in zones],
        excluded_subtrees=[x509.IPAddress(ipaddress.ip_network("0.0.0.0/0")),
                           x509.IPAddress(ipaddress.ip_network("::/0"))])


def build(zones, cn):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = datetime.datetime.now(datetime.timezone.utc)
    end = sub.not_valid_after_utc
    nc = constraints(zones)
    ski = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
    root = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now).not_valid_after(end)
            .add_extension(x509.BasicConstraints(ca=True, path_length=1), True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
            .add_extension(nc, True)
            .add_extension(ski, False)
            .sign(key, hashes.SHA256()))
    # Тот же subject и ключ, что у Sub CA Минцифры, но издатель — наш корень с ограничением зон.
    cross = (x509.CertificateBuilder().subject_name(sub.subject).issuer_name(name)
             .public_key(sub.public_key()).serial_number(x509.random_serial_number())
             .not_valid_before(now).not_valid_after(end)
             .add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
             .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
             .add_extension(nc, True)
             .add_extension(sub.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value, False)
             .add_extension(x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(ski), False)
             .sign(key, hashes.SHA256()))
    return root, cross  # key выходит из области видимости и пропадает


def pem(c):
    return c.public_bytes(serialization.Encoding.PEM)


def der(c):
    return c.public_bytes(serialization.Encoding.DER)


ZONES = ["ru", "xn--p1ai", "su"]  # xn--p1ai = .рф
root, cross = build(ZONES, "RU-only trust (.ru .rf .su) - local")
open(f"{out}/ru-only-root.crt", "wb").write(pem(root))
open(f"{out}/ru-only-sub-ca.crt", "wb").write(pem(cross))
open(f"{out}/test-leaf.pem", "wb").write(pem(leaf))

# Самопроверка: наш комплект принимает лист Сбера, а комплект «только .su» — отвергает.
def openssl_ok(r, c):
    with tempfile.TemporaryDirectory() as d:
        for n, x in (("r", r), ("c", c), ("l", leaf)):
            open(f"{d}/{n}", "wb").write(pem(x))
        return subprocess.run(["openssl", "verify", "-CAfile", f"{d}/r", "-untrusted", f"{d}/c", f"{d}/l"],
                              capture_output=True).returncode == 0


assert openssl_ok(root, cross), "свой комплект не принял лист"
assert not openssl_ok(*build(["su"], "negative")), "ограничение зон не сработало"


def payload(kind, c, name):
    return {"PayloadType": kind, "PayloadVersion": 1, "PayloadContent": der(c),
            "PayloadIdentifier": f"local.ru-only.{uuid.uuid4()}", "PayloadUUID": str(uuid.uuid4()),
            "PayloadDisplayName": name}


profile = {
    "PayloadType": "Configuration", "PayloadVersion": 1,
    "PayloadIdentifier": "local.ru-only-trust", "PayloadUUID": str(uuid.uuid4()),
    "PayloadDisplayName": "Сертификаты Минцифры только для .ru/.рф/.su",
    "PayloadDescription": "Доверие Russian Trusted Sub CA, ограниченное зонами .ru, .рф, .su. Корень Минцифры не устанавливается.",
    "PayloadContent": [payload("com.apple.security.root", root, "RU-only root"),
                       payload("com.apple.security.pkcs1", cross, "Russian Trusted Sub CA (ограниченный)")],
}
plistlib.dump(profile, open(f"{out}/ru-only.mobileconfig", "wb"))
print("ok", root.fingerprint(hashes.SHA256()).hex())
