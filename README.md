# Phigros++

**Get it with the [Phigros++ Installer](https://github.com/ggmolly/PhigrosPlusPlus-Installer/releases/latest)**, which
patches the Phigros installed from the Play Store on your phone.

Phigros++ brings mods to Phigros. It's a Lua mod loader built into the game's app: mods run inside the game, add their
own settings, pages and cosmetics next to the game's.

It comes with:

- **Replays**: every play is recorded and can be watched again from the song list, with a player to seek, pause and
  change the speed.
- **phigros.tools sync**: an opt-in profile on [phigros.tools](https://phigros.tools) with the player's records,
  replays and play stats.
- **A HUD** with the grade and accuracy the play is heading for and a hit error bar, and an option to skip the game's
  artificial loading delays.

| | |
|---|---|
| ![A song with the HUD: the grade and accuracy under the score, the hit error bar at the bottom](assets/hud.webp) | ![The replays of a chart, laid out like the song list](assets/replays.webp) |
| ![The profile page with the phigros.tools sync options](assets/profile.webp) | ![The Phigros++ settings tab](assets/settings.webp) |

The loader and these built-in mods update from inside the game. When the game itself updates, the installer patches it
again.

## Installing

Install Phigros from the Play Store, then download `phigrospp-installer.apk` from the
[installer's latest release](https://github.com/ggmolly/PhigrosPlusPlus-Installer/releases/latest) and open it. The
installer patches the Phigros on your phone into Phigros++, an app of its own next to the game, so no game files are
downloaded. It fetches the latest Phigros++ release from this repository, checked against the release key, and updates
it later the same way, keeping everything. Phigros++ starts with its own save: turn on sync in Settings → Profile to
keep it on phigros.tools, or restore your profile there to bring back the save you uploaded.

Your own mods go in `Android/data/sh.molly.phigrosplusplus/files/phigros++/mods/`. A mod runs with everything Phigros++
has, the key of your phigros.tools profile included, so only install mods you trust.

Writing mods and building Phigros++ are covered in the [wiki](https://github.com/ggmolly/PhigrosPlusPlus/wiki).
