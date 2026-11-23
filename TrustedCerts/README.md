# TrustedCerts

Optional. Certificate authority certificates (`.pem`, `.cer` or `.crt`) that the
connector should trust, for example your internal root and issuing CAs. Name the
folder in the fleet file (`TrustStore = 'TrustedCerts'`). Only files with those
three extensions are copied to the connectors; anything else in the folder is
ignored.
