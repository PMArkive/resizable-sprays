# [ANY] Resizable (and spammable) Sprays

A Sourcemod plugin that allows you to place your spray as many times as you want and as large as you want.

## FEATURES

- Place multiple sprays similar to Goldsrc
- Place sprays on brush entities similar to Goldsrc
- Dynamic resizing of player sprays

## DEPENDENCIES

FileNetMessages (Send / Request Files from clients)
https://forums.alliedmods.net/showthread.php?t=233549

## COMMANDS

`sm_spray` - Places a "world" decal. This is the default (and safer) option. World sprays can only be placed on worldspawn (non-entity) brushes, and is controlled by the client's `r_decals` cvar.  Placing too many of these will remove the oldest one.

`sm_bspray` - Places a "BSP" decal. These can be placed on any valid brush entity and do not decay. May cause issues if they are spammed on a single surface.  If the player using this command does not have the flags defined by `rspr_adminflags`, using this command will be equivalent to `sm_spray`.

## CVARS

`rspr_adminflags [b]` - Flags required to bypass spray restrictions and use BSP decals.

`rspr_delay [0.5]` - Controls delay between entering the command and placing the decal. Setting this too low may cause sprays to render incorrectly on clients. 0.5 works well enough to send the files to all clients on a 33 player server, but YMMV.

`rspr_maxspraydistance [128]` - How close a non-admin needs to be to a surface to spray in Hammer units.  0 is infinite range.

`rspr_maxsprayscale [0.2]` - Maximum scale for sprays for non-admins. Actual size depends on dimensions of your spray. For reference, a 512x512 spray at 0.25 scale will be 128x128 hammer units tall, double that of a normal 64x64 spray.

`rspr_decalfrequency [0.5]` - Spray frequency for non-admins, in seconds. 0 is no delay. May cause lag if set too low, so be careful with this.

## TODO

- Find a way to keep track of and remove decals
- Implement a spray limit per map, ideally using a queue system to remove the oldest placed spray with the newest one
- Potentially replace FileNetMessages with Late Downloads since it is apparently able to tell when a client has downloaded a file. Just need to figure out how to compile it for non-CS:GO engines.
- General code optimization and cleanup
