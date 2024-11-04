# iM@S Image Bot

This is a bot powered by bash-atproto that posts random images of 765 Production idols.



**NOTE:** This script will not work properly on macOS due to using `sed -i`.

## bash-atproto

Information about bash-atproto is currently in the [765coverbot repo](https://github.com/engielolz/765coverbot).

imasimgbot uses all of its functions except postToBluesky.

### Dependencies

To use this script you will need, at minimum:

* cURL 7.76.0 or later.

* jq

Posting images (required by imasimgbot) additionally requires:

* imagemagick (`convert` and `identify`)

The other dependencies (like uuidgen) should come with your Linux distro.

## Setup

Like 765coverbot, this is intended to be ran on an always-on system behind a router. This does not require direct internet access and ideally the server shouldn't have it.

The bot isn't ready yet, but when it is, you'll install it with these commands (as root):

1. Go to `/usr/local/bin` and `git clone` this repository

2. Run the main script with the init-secrets parameter and provide all the individual bots your Bluesky handle and app password:
   
   `./imasimgbot.sh init-secrets`

3. Run `imasimgbot.sh` with the parameter `--install` which will install and enable the bot service

4. Start the bot with `systemctl start imasimgbot`

To uninstall the bot, stop the bot with `systemctl stop imasimgbot` then run the script as root with the parameter `--uninstall` which will disable and remove the service file. Then you can remove the directory `/usr/local/bin/imasimgbot` to fully remove the bot.
