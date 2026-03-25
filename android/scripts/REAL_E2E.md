# Real E2E profile file

Create untracked file `android/local-test-profile.json`:

```json
{
  "name": "E2E Profile",
  "addr": "89.110.109.128:8443",
  "sni": "vpn.example.com",
  "tun": "10.7.0.2/24",
  "cert": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "ca": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "admin": {
    "url": "http://10.7.0.1:8080",
    "token": "secret-token"
  }
}
```

Run:

```bash
cd android
./scripts/run_real_e2e.sh
```
