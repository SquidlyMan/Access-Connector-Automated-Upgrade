# Roadmap

Known gaps and planned work, most useful first. Items 2 and 3 under Next are tracked as issues 2 and 3 on the repository.

## Next

### 1. Service selection for a connector or group of connectors (done)

Services are chosen per connector group (one fleet entry), and a group can hold a single connector. This is documented in Getting Started section 11 and in the Fleet File Reference. Issue 1 is closed.

Small follow-ups, not scheduled: have Verify and the plan show installed services against wanted services and say when a forced reinstall is needed; print a reminder to disable the connector's Active Directory account when Kerberos Auth is removed.

### 2. Carry the remaining installer settings through the fleet file

The wrapper already accepts proxy host, port, user and password, non-proxy hosts, custom service ports, install folder and FIPS mode. The fleet file and job do not pass them. Add them, with the proxy password asked at run time like the others.

### 3. Prove the unproven paths

From the Validation Record: the certificate step inside a real upgrade, WinRM with Kerberos Auth connectors, `-Parallel`, `-ParallelTenants`, `-Schedule`, SSH modes from Windows and Linux admin machines, cmd.exe as the SSH default shell.

## Later

- **WinRM parity:** Verify, RepairKeytab and RepairCertificate over WinRM; logs copied back in WinRM mode.
- **Generic post-install step:** the patch step is tied to the Java4Shell patch and its flag. Make it a named script and an optional check, so a future vendor patch needs no code change.
- **Compatibility pre-check:** warn when the installer version is not listed as a supported upgrade from the installed version.
- **Clean-up option:** remove the staged installer, configuration file and PFX from the connector after a successful run.
- **Certificate expiry warning** in Verify, a set number of days ahead.
- **Wrapper fixes:** the served-certificate comparison under Windows PowerShell 5.1; the keytab-log check reading only the newest result.
- **Tests:** a scripted self-test that needs no connector (fleet-file parsing, plan, missing-file messages, log cleaning), runnable in continuous integration.
- **Licence:** choose one before the repository is made public.
