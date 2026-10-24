#!/usr/bin/env python3
"""Builds ZigzagTests/Fixtures/firefox-profile: a tiny Firefox profile with known keys, written from NSS's documented
formats with Python's hashlib and the openssl command (not Zigzag's code), so the importer is tested against
an outside answer. Primary password: "" (none). One login: https://example.com / octocat / zigzag-firefox-test."""
import base64, hashlib, json, os, sqlite3, subprocess, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def tlv(tag, value):
    n = len(value)
    if n < 0x80: length = bytes([n])
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, 'big'); length = bytes([0x80 | len(b)]) + b
    return bytes([tag]) + length + value
seq = lambda *items: tlv(0x30, b''.join(items))
octet = lambda b: tlv(0x04, b)
def integer(i): b = i.to_bytes(max(1, (i.bit_length() + 8) // 8), 'big'); return tlv(0x02, b)
def oid(dotted):
    parts = [int(p) for p in dotted.split('.')]
    body = bytes([parts[0] * 40 + parts[1]])
    for p in parts[2:]:
        chunk = [p & 0x7f]; p >>= 7
        while p: chunk.insert(0, 0x80 | (p & 0x7f)); p >>= 7
        body += bytes(chunk)
    return tlv(0x06, body)

def openssl(cipher, key, iv, data):
    return subprocess.run(['openssl', 'enc', '-' + cipher, '-K', key.hex(), '-iv', iv.hex()], input=data, capture_output=True, check=True).stdout

global_salt = bytes(range(20))
primary = b''
def pbes2(plain, entry_salt, iv14, iterations=1):
    k = hashlib.sha1(global_salt + primary).digest()
    key = hashlib.pbkdf2_hmac('sha256', k, entry_salt, iterations, 32)
    ct = openssl('aes-256-cbc', key, b'\x04\x0e' + iv14, plain)
    return seq(seq(oid('1.2.840.113549.1.5.13'),
                   seq(seq(oid('1.2.840.113549.1.5.12'), seq(octet(entry_salt), integer(iterations), integer(32), seq(oid('1.2.840.113549.2.9')))),
                       seq(oid('2.16.840.1.101.3.4.1.42'), octet(iv14)))),
               octet(ct))

login_key = bytes(range(100, 124))  # 24 bytes, 3DES
check = pbes2(b'password-check\x02\x02', bytes(range(32)), bytes(range(14)))
wrapped = pbes2(login_key, bytes(range(32, 64)), bytes(range(14, 28)))

db = os.path.join(out, 'key4.db')
if os.path.exists(db): os.remove(db)
c = sqlite3.connect(db)
c.execute('CREATE TABLE metaData (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2)')
c.execute('INSERT INTO metaData VALUES (?, ?, ?)', ('password', global_salt, check))
c.execute('CREATE TABLE nssPrivate (id PRIMARY KEY UNIQUE ON CONFLICT ABORT, a11, a102)')
c.execute('INSERT INTO nssPrivate VALUES (?, ?, ?)', (1, wrapped, b'\xf8' + b'\x00' * 14 + b'\x01'))
c.commit(); c.close()

def field(text, iv):
    ct = openssl('des-ede3-cbc', login_key, iv, text.encode())
    return base64.b64encode(seq(octet(b'\xf8' + b'\x00' * 14 + b'\x01'), seq(oid('1.2.840.113549.3.7'), octet(iv)), octet(ct))).decode()

json.dump({'nextId': 2, 'logins': [{
    'id': 1, 'hostname': 'https://example.com', 'httpRealm': None, 'formSubmitURL': 'https://example.com',
    'encryptedUsername': field('octocat', bytes(range(8))), 'encryptedPassword': field('zigzag-firefox-test', bytes(range(8, 16))),
    'timeCreated': 1767225600000, 'timeLastUsed': 1767225600000, 'timePasswordChanged': 1767225600000, 'timesUsed': 1}]},
    open(os.path.join(out, 'logins.json'), 'w'))
print('wrote', out)
