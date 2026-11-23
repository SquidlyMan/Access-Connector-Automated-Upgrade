# Configs

Put each tenant's `es-config.json` here (downloaded from the Access console when
a connector is added) and name it in the fleet file
(`ConfigFile = 'Configs\<file name>.json'`). Give each tenant's file its own
name.

The file holds tenant details and a password hash. Its password is asked for at
run time and is never stored. Do not commit these files (see `.gitignore`).
