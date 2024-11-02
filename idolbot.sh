#!/bin/bash

function loadFail () {
   echo "Cannot load required dependency script"
   exit 127
}

function showHelp () {
   echo "usage: ./idolbot.sh <idol> <command>"
   echo "commands:"
   echo "login - specify a did/handle and app-password to generate secrets"
   echo "post - normal behavior to post an image"
   echo "repost - repost another idol bot's post"
}

source ./bash-atproto.sh
if ! [ "$?" = "0" ]; then loadFail; fi

# Check params
if [ -z "$1" ]; then showHelp badParam; exit 1; fi
if [ "$1" = "--help" ]; then showHelp; exit 0; fi


function login () {
   if [ -z "$1" ] || [ -z "$2" ]; then $iecho "login params not specified"; return 1; fi
   getKeys $1 $2
   if ! [ "$?" = "0" ]; then $iecho "failed to log in"; return 1
   else saveKeys ./data/$idol/secrets.env
   return 0
   fi
}

function checkRefresh () {
   if [ "$(date +%s)" -gt "$(( $savedAccessTimestamp + 5400 ))" ]; then # refresh every 90 minutes
      $iecho "Refreshing tokens"
      refreshKeys
      if ! [ "$?" = "0" ]; then
         $iecho "Refresh error. Exiting."
         exit 1
      fi
      saveSecrets data/$idol/secrets.env
   fi
}

function repostLogic () {
   $iecho "Going to repost."
   checkRefresh
   $iecho "Reposting $1 with CID $2"
   repostToBluesky $1 $2
   if [ "$?" != "0" ]; then
      $iecho "Error when trying to repost."
      return 1
   else
      $iecho "Repost succeeded."
      return 0
   fi
}

function pickImage () {
   imageNumber=$((1 + $RANDOM % $1 ))
   echo $(echo "$images" | sed -n $imageNumber'p')
   return
}

function postingLogic () {
   case "$(date +%m%d)" in

      "0109" | "0401")
      event=fools
      ;;

      "1031")
      event=halloween
      ;;

      "1224" | "1225" )
      event=christmas
      ;;

      *)
      event=regular
      ;;
   esac
   if ! [ -f data/$idol/images/$event.txt ]; then event=regular; fi
   $iecho "Event: $event"
   images=$(grep -xvf data/$idol/recent.txt data/$idol/images/$event.txt)
   if [ -z "$images" ]; then
      $iecho "warning: all $event images in recents. falling back to regular"
      images=$(grep -xvf data/$idol/recent.txt data/$idol/images/regular.txt)
      if [ -z "$images" ]; then
         $iecho "warning: all regular images used recently! ignoring recents.txt"
         images=$(cat data/$idol/images/regular.txt)
      fi
   fi
   image=$(pickImage $(echo "$images" | wc -l))
   $iecho "picked image $image"
   # very dirty loadSecrets call, not using it as intended
   loadSecrets data/$idol/images/$image/info.txt
   if ! [ "$?" = "0" ]; then
      echo $iecho "fatal: the image data for $image is missing"
      echo $iecho "hint: if the above line is broken, it may be encoded in windows format"
      return 1
   fi
   $iecho "alt text: $alt"
   if [ -z "$otheridols" ]; then
      $iecho "image does not have other idols"
   else
      $iecho "image has other idols: $otheridols"
   fi
   # images=$(cat data/$idol/images/$event.txt)
   return 0
}

if ! [ -d ./data/$1 ]; then echo "idolbot: No such idol: $1"; exit 1; fi

idol=$1
iecho="echo $idol:"
loadSecrets data/$idol/secrets.env
if ! [ "$?" = "0" ]; then
   if ! [ "$2" = "login" ]; then $iecho "you need to login first."; exit 1; fi
   login $3 $4
   exit $?
fi
if [ "$2" = "login" ]; then
   if [ "$3" = "--force" ]; then login $4 $5
   else $iecho "you are already logged in. Pass --force to log in anyway"; fi
fi

if [ "$2" = "post" ]; then postingLogic; fi
if [ "$2" = "repost" ]; then repostLogic $3 $4; fi
if [ -z "$2" ]; then $iecho "no operation specified"; exit 1; fi
