#!/bin/bash

function iberr () {
   >&2 $iecho $*
}

function loadFail () {
   >&2 echo "Cannot load required dependency script"
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
   if [ -z "$1" ] || [ -z "$2" ]; then iberr "login params not specified"; return 1; fi
   didInit $1
   if ! [ "$?" = "0" ]; then iberr "did init failure"; return 1; fi
   getKeys $did $2
   if ! [ "$?" = "0" ]; then iberr "failed to log in"; return 1; fi
   saveSecrets ./data/$idol/secrets.env
   return 0
}

function interactiveLogin () {
   read -p "$idol: Handle: " handle
   read -sp "$idol: App Password: " apppassword
   echo
   didInit $handle
   if ! [ "$?" = "0" ]; then iberr "did init failure"; return 1; fi
   getKeys $did $apppassword
   if ! [ "$?" = "0" ]; then iberr "failed to log in"; return 1; fi
   saveSecrets ./data/$idol/secrets.env
   apppassword=
   return 0
}

function checkRefresh () {
   if [ "$(date +%s)" -gt "$(( $savedAccessTimestamp + 5400 ))" ]; then # refresh every 90 minutes
      $iecho "Refreshing tokens"
      refreshKeys
      if ! [ "$?" = "0" ]; then
         iberr "Refresh error. Exiting."
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
      iberr "Error when trying to repost."
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

function incrementRecents () {
   $iecho "adding image to recents"
   if ! [ -s data/$idol/$event-recents.txt ]; then echo "" > data/$idol/$event-recents.txt; fi
   sed -i "1s/^/$image\n/" data/$idol/$event-recents.txt
   return 0
}

function idolReposting () {
   $iecho "reposting for idols $otheridols"
   echo $otheridols | tr ',' '\n' | while read ridol; do
      env -i $0 $ridol repost $uri $cid
   done
   return 0
}

function postIdolPic () {
   $iecho "preparing image"
   checkRefresh
   prepareImageForBluesky $imagepath
   if [ "$?" != "0" ]; then
      iberr "fatal: image prep failed!"
      if [ -f $preparedImage ]; then rm -f $preparedImage; fi
      return 1
   fi
   $iecho "uploading image to pds"
   postBlobToPDS $preparedImage $preparedMime
   if [ "$?" != "0" ]; then
      iberr "fatal: blob posting failed!"
      if [ -f $preparedImage ]; then rm -f $preparedImage; fi
      return 1
   fi
   rm $preparedImage
   # check preparedMime/postedMime and preparedSize/postedSize
   $iecho "posting image"
   postImageToBluesky $postedBlob $postedMime $postedSize "$alt"
   if [ "$?" != "0" ]; then
      iberr "fatal: image posting failed!"
      return 1
   fi
   $iecho "image upload SUCCESS"
   return 0
}

function postIdolVideo () {
   checkRefresh
   $iecho "uploading video to pds"
   postBlobToPDS $imagepath "video/mp4"
   if [ "$?" != "0" ]; then
      iberr "fatal: blob posting failed!"
      return 1
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   $iecho "posting video"
   postVideoToBluesky $postedBlob $postedSize "$alt"
   if [ "$?" != "0" ]; then
      iberr "fatal: video posting failed!"
      return 1
   fi
   $iecho "video upload SUCCESS (may take time to process)"
   return 0
}

function eventHandler () {
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
}

function postingLogic () {
   dryrun=0
   if [ "$1" = "--no-post" ]; then dryrun=1; fi
   if [ "$1" = "--dry-run" ]; then dryrun=2; fi
   eventHandler
   if ! [ -f data/$idol/$event-recents.txt ]; then touch data/$idol/$event-recents.txt; fi
   $iecho "Event: $event"
   images=$(grep -xvf data/$idol/$event-recents.txt data/$idol/images/$event.txt)
   if [ -z "$images" ]; then
      $iecho "resetting recents queue for $event"
      echo > data/$idol/$event-recents.txt
      images=$(grep -xvf data/$idol/$event-recents.txt data/$idol/images/$event.txt)
   fi
   image=$(pickImage $(echo "$images" | wc -l))
   $iecho "picked entry $image"
   # very dirty loadSecrets call, not using it as intended
   loadSecrets data/$idol/images/$image/info.txt
   if ! [ "$?" = "0" ]; then
      echo iberr "fatal: the entry data for $image is missing"
      echo iberr "hint: if the above line is broken, it may be encoded in windows format"
      return 1
   fi
   imagepath=data/$idol/images/$image/image.$imgtype
   if ! [ -f $imagepath ]; then iberr "fatal: image $imagepath does not exist"; return 1; fi
   $iecho "location: $imagepath"
   $iecho "alt text: $alt"
   if [ -z "$otheridols" ]; then
      $iecho "entry does not have other idols"
   else
      $iecho "entry has other idols: $otheridols"
   fi
   if [ "$dryrun" = "0" ]; then
      if ! [ "$imgtype" = "mp4" ]; then postIdolPic; else postIdolVideo; fi
      if [ "$?" != "0" ]; then
         iberr "fatal: failed to post!"
         return 1
      fi
   else
      $iecho "skipping post because --dry-run or --no-post specified"
   fi
   if ! [ "$dryrun" = "2" ]; then incrementRecents $image; fi
   if ! [ -z "$otheridols" ];  then
      if [ "$dryrun" = "0" ]; then idolReposting
      else $iecho "not reposting because --dry-run or --no-post specified"; fi
   fi
   return 0
}

if ! [ -d ./data/$1 ]; then
   >&2 echo "idolbot: No such idol: $1"; exit 1; fi

idol=$1
iecho="echo $idol:"
loadSecrets data/$idol/secrets.env
if ! [ "$?" = "0" ]; then
   if ! [ "$2" = "login" ]; then iberr "you need to login first."; exit 1; fi
   if ! [ "$3" = "--interactive" ]; then
      login $3 $4
   else
      interactiveLogin
   fi
   exit $?
fi
if [ "$2" = "login" ]; then
   if [ "$3" = "--force" ]; then
      login $4 $5
      exit $?
   else
      iberr "you are already logged in. Pass --force to log in anyway"
      exit 2
   fi
fi
did=$savedDID
if [ "$2" = "post" ]; then postingLogic $3; fi
if [ "$2" = "repost" ]; then repostLogic $3 $4; fi
if [ -z "$2" ]; then iberr "no operation specified"; exit 1; fi
