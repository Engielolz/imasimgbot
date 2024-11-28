#!/bin/bash
echo 'iM@S Image Bot'
echo 'Powered by bash-atproto'

function loadFail () {
   echo "Required scripts not found!"
   exit 127
}

function installService () {
   if ! [[ -d /run/systemd/system ]]; then echo "No systemd detected. Please manage the service manually with your init system."; exit 1; fi
   if ! [ "$1" = "un" ]; then
      echo "Installing service"
      ln -sf $(realpath ./imasimgbot.service) /etc/systemd/system/
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
   for i in $(seq 1 $(cat data/idols.txt | wc -l)); do
      ./idolbot.sh $(cat data/idols.txt | sed -n $i'p') login --interactive
      if [ "$?" = "1" ]; then exit 1; fi
   done
   exit 0
}

source bash-atproto.sh
if ! [ "$?" = "0" ]; then loadFail; fi

if [ "$1" = "--install" ]; then installService; fi
if [ "$1" = "--uninstall" ]; then installService un; fi

if [ "$1" = "init-secrets" ]; then loginAll; fi
if [ "$1" = "--post-now" ]; then postAll; exit 0; fi

# postInterval=3600 # post every hour
postInterval=7200 # post every 2 hours

function napTime () {
   sleeptime=$(($1 - $(date +%s) % $1))
   echo "Sleeping until $(date -d @$(($(date +%s) + $sleeptime)))"
   sleep $sleeptime
}

function postAll () {
   for i in $(seq 1 $(cat data/idols.txt | wc -l)); do
      ./idolbot.sh $(cat data/idols.txt | sed -n $i'p') post
   done
}

while :
do
   napTime $postInterval
   postAll
done
