# Roadmap

Known gaps and planned work, most useful first. Item 3 under Next is tracked as issue 3 on the repository.

## Next

### 1. Service selection for a connector or group of connectors (done)

Services are chosen per connector group (one fleet entry), and a group can hold a single connector. This is documented in Getting Started section 11 and in the Fleet File Reference. Issue 1 is closed.

Small follow-ups, not scheduled: have Verify and the plan show installed services against wanted services and say when a forced reinstall is needed; print a reminder to disable the connector's Active Directory account when Kerberos Auth is removed.

### 2. Carry the remaining installer settings through the fleet file (done in 1.4.0)

Install folder, FIPS mode, service ports and outbound proxy are fleet-file settings; the proxy password is asked at run time. Issue 2. Not yet proven by a real run (Validation Record).

### 3. Prove the unproven paths

From the Validation Record: the certificate step inside a real upgrade (needs the next connector release: a forced reinstall is a fresh install, where the installer keeps the PFX), WinRM with Kerberos Auth connectors, `-Parallel`, `-ParallelTenants`, `-Schedule`, SSH modes from Windows and Linux admin machines, cmd.exe as the SSH default shell, the 1.4.0 installer settings, and the 1.4.0 wrapper checks.

## Later

- **WinRM parity:** Verify, RepairKeytab and RepairCertificate over WinRM; logs copied back in WinRM mode.
- **Generic post-install step:** the patch step is tied to the Java4Shell patch and its flag. Make it a named script and an optional check, so a future vendor patch needs no code change.
- **Compatibility pre-check:** warn when the installer version is not listed as a supported upgrade from the installed version.
- **Clean-up option:** remove the staged installer, configuration file and PFX from the connector after a successful run.
- **Certificate expiry warning** in Verify, a set number of days ahead.
- **Tests:** a scripted self-test that needs no connector (fleet-file parsing, plan, missing-file messages, log cleaning), runnable in continuous integration.
