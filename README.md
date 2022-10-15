# [ANY] Resizable (and spammable) Sprays

[AlliedModders thread](https://forums.alliedmods.net/showthread.php?p=2746552)

A Sourcemod plugin that allows you to place your spray as many times as you want and as large as you want.

## FEATURES

- Place multiple sprays similar to Goldsrc
- Place sprays on brush entities similar to Goldsrc
- Dynamic resizing of player sprays

## DEPENDENCIES

[My LateDL fork](https://gitgud.io/sappykun/late-downloads-2/-/tree/dev) (uses a different include file from the original)

## COMMANDS

`sm_spray` - Places a "world" decal. This is the default (and safer) option. World sprays can be placed on any valid brush entity, and are controlled by the client's `r_decals` cvar.  Placing too many of these will remove the oldest one.

`sm_bspray` - Places a "BSP" decal. These are "permanent" and do not decay. Will cause decals to stop appearing if there are too many BSP decals, so be mindful of that.  If the player using this command does not have the flags defined by `rspr_adminoverride`, using this command will be equivalent to `sm_spray`.

`sm_sprayinfo` - Displays who is downloading your spray and which sprays you are downloading. Only admins can see status of other users, normal players will only be able to run the command on themselves. 

## CVARS

`rspr_enabled [1]` - Enables the plugin.

`rspr_loglevel [2]` - Logging level. Higher number = more console spam, but makes debugging easier.

`rspr_maxspraydistance [128]` - How close a non-admin needs to be to a surface to spray in Hammer units.  0 is infinite range.

`rspr_maxsprayscale [2.0]` - Maximum scale for sprays for non-admins.  For reference, a spray with scale 1.0 will be 64x64 Hammer units in size (the default size for regular sprays).

`rspr_maxsprayscale_absolute [32.0]` - Maximum scale for all sprays.

`rspr_decalfrequency [0.5]` - Spray frequency for non-admins, in seconds. 0 is no delay. May cause lag if set too low, so be careful with this.

`rspr_spraytimeout [10.0]` - Max time to wait for clients to download spray files. 0 will wait forever, but I recommend setting this to something lower like 1 second.


## TODO

- ~~Find a way to keep track of and remove decals~~ (infodecals are deleted clientside and cannot be manipulated)
- ~~Implement a spray limit per map, ideally using a queue system to remove the oldest placed spray with the newest one~~ (sprays will clean themselves up based on the client's `r_decals` cvar)
- General code optimization and cleanup
