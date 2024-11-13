# iM@S Image Bot

This is a bot powered by bash-atproto that posts random images of 765 Production idols.

**NOTE:** This script will not work properly on macOS due to using `sed -i`.

## bash-atproto

Information about bash-atproto is currently in the [765coverbot repo](https://github.com/engielolz/765coverbot).

imasimgbot uses all of its functions except postToBluesky.

### Dependencies

bash-atproto needs, at minimum:

* `curl` 7.76.0 or later.

* `jq`

Posting images (required by imasimgbot) additionally requires:

* imagemagick (`convert` and `identify`)
* `exiftool`

The other dependencies (like uuidgen) should come with your Linux distro.

## Setup

Like 765coverbot, this is intended to be ran on an always-on system behind a router. This does not require direct internet access and ideally the server shouldn't have it.

The bot can be installed with these commands (as root):

1. Go to `/usr/local/bin` and `git clone` this repository

2. Create the data directory and [its required structure](docs/structure.md).

3. Run the main script with the init-secrets parameter and provide all the individual bots their Bluesky handle and app password:
   
   `./imasimgbot.sh init-secrets`

4. Run `imasimgbot.sh` with the parameter `--install` which will install and enable the bot service

5. Start the bot with `systemctl start imasimgbot`

To uninstall the bot, stop the bot with `systemctl stop imasimgbot` then run the script as root with the parameter `--uninstall` which will disable and remove the service file. Then you can remove the directory `/usr/local/bin/imasimgbot` to fully remove the bot.
