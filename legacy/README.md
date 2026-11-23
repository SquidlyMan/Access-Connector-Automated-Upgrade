# Legacy

`Update-AccessConnectorFleet.ps1` is the earlier fleet updater (July 2026). It
works over PowerShell remoting only, uses a different fleet-file layout (one PFX
per connector, `Computer` instead of `Host`) and needs CredSSP for Kerberos
connectors. It is kept for reference and is not used by the current tool.

Use `FleetDeploy/Invoke-AccessConnectorUpgrade.ps1` instead.
