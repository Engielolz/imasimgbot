# iM@S Image Bot

This is a bot powered by [bash-atproto](https://tangled.sh/@did:plc:s2cyuhd7je7eegffpnurnpud/bash-atproto) that can randomly post images to Bluesky with a number of atproto accounts.

The main use case is to post random images of 765 Production idols.

## Dependencies

There are no further requirements beyond meeting the requirements of bash-atproto.

## Install

Please see the [quick start guide](docs/QSG.md) for instructions on how to use the bot.

The bot can be installed with these commands (as root):

1. Go to `/usr/local/bin` and `git clone --recurse-submodules` this repository

2. Add your images and set up accounts in ./data. See the [quick start guide](docs/QSG.md) and [structure.md](docs/structure.md) for instructions.

3. Run `./imasimgbot.sh --install` which will install and enable the bot service

4. Start the bot with `systemctl start imasimgbot`

To uninstall the bot, stop the bot with `systemctl stop imasimgbot` then run the script as root with the parameter `--uninstall` which will disable and remove the service file. Then you can remove the directory `/usr/local/bin/imasimgbot` to fully remove the bot.

## Update

After running the usual `git pull`, you should run `git submodule update` to update bash-atproto. imasimgbot will throw errors if it needs a newer bash-atproto.

## License

This project (including bash-atproto) is licensed under the [MIT License](LICENSE). PRs welcome, but note that this is hobbyist-grade software. imasimgbot is not recommended for use in safety-critical applications like nuclear power plants, weapon control systems or multimillionaire Japanese idol agencies. Well, maybe not that last one...
