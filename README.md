# iM@S Image Bot

This is a bot powered by bash-atproto that posts random covers by 765 Production idols.

This bot is currently under development and does not function yet.

## bash-atproto

Information about bash-atproto is currently in the [765coverbot repo](https://github.com/engielolz/765coverbot).

The version of bash-atproto in this repo is newer however and is not fully compatible with 765coverbot. This will change soon.

### Dependencies

To use this script you will need, at minimum:

* cURL 7.76.0 or later.

* jq

Posting images (required by imasimgbot) additionally requires:

* imagemagick (convert)

The other dependencies should come with your Linux distro.

## Setup

Like 765coverbot, this is intended to be ran on an always-on system behind a router. This does not require direct internet access and the server ideally shouldn't have it.

The bot isn't ready yet, but when it is, you'll install it with these commands (as root):

1. Go to `/usr/local/bin` and `git clone` this repository

2. Run the main script with the init-secrets parameter and provide all the individual bots your Bluesky handle and app password:
   
   `./imasimgbot.sh init-secrets`

3. Run `imasimgbot.sh` with the parameter `--install` which will install and enable the bot service

4. Start the bot with `systemctl start imasimgbot`

To uninstall the bot, stop the bot with `systemctl stop imasimgbot` then run the script as root with the parameter `--uninstall` which will disable and remove the service file. Then you can remove the directory `/usr/local/bin/imasimgbot` to fully remove the bot.
