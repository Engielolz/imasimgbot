#!/bin/bash
# SPDX-License-Identifier: MIT
echo 'iM@S Image Bot'
echo 'Powered by bash-atproto'
export svcInterval=900 # fire every 15 minutes

function installService () {
   if ! [[ -d /run/systemd/system ]]; then echo "No systemd detected. Please manage the service manually with your init system."; exit 1; fi
   if ! [ "$1" = "un" ]; then
      echo "Installing service"
      ln -sf "$(realpath ./imasimgbot.service)" /etc/systemd/system/
      systemctl enable imasimgbot
      echo "The script will activate when you restart the system."
      echo "Or you can start it now with: systemctl start imasimgbot"
   else
      echo "Removing service"
      systemctl disable imasimgbot
      #systemd deletes the symlink for us
   fi
   exit 0
}

function loginAll () {
   for i in $(seq 1 "$(wc -l < data/idols.txt)"); do
      ./idolbot.sh "$(sed -n "$i"'p' < data/idols.txt)" login --interactive
      if [ "$?" = "1" ]; then exit 1; fi
   done
   exit 0
}

function postAll () {
   for i in $(seq 1 "$(wc -l < data/idols.txt)"); do
      ./idolbot.sh "$(sed -n "$i"'p' < data/idols.txt)" post-timer &
      if [ "$(jobs -p | wc -l)" -ge "$(nproc)" ]; then wait -n; fi
   done
   wait
}

case "$1" in
    "--install") installService;;
    "--uninstall") installService un;;
    "init-secrets") loginAll;;
    "--post-now") postAll; exit 0;;
esac

function napTime () {
   sleeptime=$(($1 - $(date +%s) % $1))
   echo "Sleeping until $(date -d @$(($(date +%s) + sleeptime)))"
   sleep $sleeptime
}

while :
do
   napTime $svcInterval
   postAll
done
