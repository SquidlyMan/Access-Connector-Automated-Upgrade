# ChildCerts

Only needed for connectors that run the Kerberos Auth service.

Put the PFX (certificate plus private key) that the Kerberos Auth service should
present here and name it in the fleet file (`Pfx = 'ChildCerts\<file>.pfx'`).
The certificate must name every connector it is used on (subject alternative
names), plus any load-balancer name clients use.

For `-Mode RepairCertificate` the file name may hold only letters, digits, dot,
dash and underscore. The PFX password is asked for at run time. Do not commit
PFX files (see `.gitignore`).
