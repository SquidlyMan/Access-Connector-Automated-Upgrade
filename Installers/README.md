# Installers

Put the Omnissa Access Connector installer here, for example
`Access-Connector-Installer-<version>.exe`, and name it in the fleet file
(`Installer = 'Installers\<file name>'`). Any version works: the tool installs
whichever file the fleet file points at.

Optional: a `Java4shellPatch` folder holding the vendor `Java4shellPatch.bat`
(Omnissa HW-283446, for connector 26.05 and 26.10). Name it in the fleet file
with `JavaPatchDir = 'Installers\Java4shellPatch'`. Leave `JavaPatchDir` out for
versions that do not need the patch.

Installers and patches are Omnissa's. Download them from Omnissa; they are not
stored in this repository (see `.gitignore`).
