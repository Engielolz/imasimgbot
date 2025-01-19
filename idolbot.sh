#!/bin/bash
internalIdolVer=2
svcInterval=900 # must match postInterval in imasimgbot.sh

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

function loadConfig () {
   if [[ -f $1 ]]; then while IFS= read -r line; do
      # Don't read comments (like this one)
      if [[ $line = \#* ]] || [ -z "$line" ]; then continue; fi
      declare -g "$line"
   done < "$1"
   return 0
   else return 1
   fi
}

source ./bash-atproto.sh
if ! [ "$?" = "0" ]; then loadFail; fi

# Check params
if [ -z "$1" ]; then showHelp badParam; exit 1; fi
if [ "$1" = "--help" ]; then showHelp; exit 0; fi

function refreshTxtCfg () {
   $iecho "updating idol.txt to new version"
   if [ -z "$postInterval" ]; then postInterval=4; fi
   if [ -z "$globalQueueSize" ]; then globalQueueSize=24; fi
   if [ -z "$clearImageOverride" ]; then clearImageOverride=1; fi
   cat >data/$idol/idol.txt <<EOF
# Version of this file. Don't touch this.
idolTxtVersion=$internalIdolVer
# Unix timestamp for next post. Don't touch this either.
nextPostTime=$nextPostTime

# Post every # runs (default 15 minutes)
postInterval=$postInterval
# The # latest used images will not be posted. Set to 0 to disable
globalQueueSize=$globalQueueSize
# Date to run the birthday event (MMDD, always in JST)
birthday=$birthday

# Enter the name of an image to post it instead of picking
imageOverride=$imageOverride
# Set this to 0 to always post the override (otherwise it's posted only once)
clearImageOverride=$clearImageOverride
EOF
}

function updateIdolTxt () {
   sed -i "s/$1=${!1}/$1=$2/g" data/$idol/idol.txt
}

function login () {
   if [ -z "$2" ]; then iberr "login params not specified"; return 1; fi
   bap_didInit $1
   if ! [ "$?" = "0" ]; then iberr "did init failure"; return 1; fi
   bap_findPDS $did
   if ! [ "$?" = "0" ]; then iberr "failed to resolve PDS"; return 1; fi
   bap_getKeys $did $2
   if ! [ "$?" = "0" ]; then iberr "failed to log in"; return 1; fi
   bap_saveSecrets ./data/$idol/secrets.env
   return 0
}

function interactiveLogin () {
   read -p "$idol: Handle: " handle
   read -sp "$idol: App Password: " apppassword
   echo
   bap_didInit $handle
   if ! [ "$?" = "0" ]; then iberr "did init failure"; return 1; fi
   bap_findPDS $did
   if ! [ "$?" = "0" ]; then iberr "failed to resolve PDS"; return 1; fi
   bap_getKeys $did $apppassword
   if ! [ "$?" = "0" ]; then iberr "failed to log in"; return 1; fi
   bap_saveSecrets ./data/$idol/secrets.env
   apppassword=
   return 0
}

function checkRefresh () {
   if [ "$(date +%s)" -gt "$(( $savedAccessTimestamp + 5400 ))" ]; then # refresh every 90 minutes
      $iecho "Refreshing tokens"
      bap_refreshKeys
      if ! [ "$?" = "0" ]; then
         iberr "fatal: refresh error"
         return 1
      fi
      bap_saveSecrets data/$idol/secrets.env
      return 0
   fi
}

function repostLogic () {
   $iecho "Going to repost."
   checkRefresh
   if [ "$?" != "0" ]; then return 1; fi
   $iecho "Reposting $1 with CID $2"
   bap_repostToBluesky $1 $2
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
   if ! [ -s $1 ]; then echo "" > $1; fi
   sed -i "1s/^/$image\n/" $1
   return 0
}

function incrementGlobalRecents () {
   if ! [ -s data/$idol/recents.txt ]; then echo "" > data/$idol/recents.txt; fi
   sed -i "1s/^/$image\n/" data/$idol/recents.txt
   if [ -z "$globalQueueSize" ]; then globalQueueSize=24; fi
   ((globalQueueSize+=1))
   sed -i "$globalQueueSize,$ d" data/$idol/recents.txt
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
   bap_prepareImageForBluesky $imagepath
   if [ "$?" != "0" ]; then
      iberr "fatal: image prep failed!"
      if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
      return 1
   fi
   if ! [ "$dryrun" = "0" ]; then
      $iecho "skipping post because --dry-run or --no-post specified"
      rm $bap_preparedImage
      return 0
   fi
   checkRefresh
   if [ "$?" != "0" ]; then rm -f $bap_preparedImage; return 1; fi
   $iecho "uploading image to pds"
   bap_postBlobToPDS $bap_preparedImage $bap_preparedMime
   if [ "$?" != "0" ]; then
      iberr "fatal: blob posting failed!"
      if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
      return 1
   fi
   rm $bap_preparedImage
   # check preparedMime/postedMime and preparedSize/postedSize
   $iecho "posting image"
   bap_postImageToBluesky $bap_postedBlob $bap_postedMime $bap_postedSize $bap_imageWidth $bap_imageHeight "$alt"
   if [ "$?" != "0" ]; then
      iberr "fatal: image posting failed!"
      return 1
   fi
   $iecho "image upload SUCCESS"
   return 0
}

function postIdolVideo () {
   checkRefresh
   if [ "$?" != "0" ]; then return 1; fi
   $iecho "uploading video to pds"
   bap_postBlobToPDS $imagepath "video/mp4"
   if [ "$?" != "0" ]; then
      iberr "fatal: video upload failed!"
      return 1
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   $iecho "posting video"
   bap_postVideoToBluesky $bap_postedBlob $bap_postedSize $bap_imageWidth $bap_imageHeight "$alt"
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
   if [ "$(TZ=Asia/Tokyo date +%m%d)" = "$birthday" ]; then event=birthday; fi
   if ! [ -f data/$idol/images/$event.txt ]; then event=regular; fi
}

function checkImage () {
   images=$(grep -xvf data/$idol/recents.txt -f data/$idol/$event-recents.txt data/$idol/images/$event.txt)
   if [ -z "$images" ]; then
      $iecho "resetting recents queue for $event"
      echo > data/$idol/$event-recents.txt
      images=$(grep -xvf data/$idol/recents.txt -f data/$idol/$event-recents.txt data/$idol/images/$event.txt)
   fi
   if [ -z "$(grep -xvf data/$idol/recents.txt data/$idol/images/$event.txt)" ]; then
         iberr "warning: the global recents queue is too big for the event $event"
         iberr "hint: in idol.txt, set globalQueueSize to a lower value"
         images=$(grep -xvf data/$idol/$event-recents.txt data/$idol/images/$event.txt)
   fi
   if [ -z "$images" ]; then iberr "error: no valid image entries"; return 1; fi
   image=$(pickImage $(echo "$images" | wc -l))
   $iecho "picked entry $image"
}

function loadImage () {
   loadConfig data/$idol/images/$image/info.txt
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
   return 0
}

function postTimer () {
   # if not next post time, return and do nothing
   if [ "$nextPostTime" -gt "$(date +%s)" ]; then return 0; fi
   postingLogic
   if ! [ "$?" = "0" ]; then return 1; fi
   updateIdolTxt nextPostTime $(($(date +%s) + (($postInterval * $svcInterval) - $(date +%s) % ($postInterval * $svcInterval))))
   return 0;
}

function postingLogic () {
   dryrun=0
   if [ "$1" = "--no-post" ]; then dryrun=1; fi
   if [ "$1" = "--dry-run" ]; then dryrun=2; fi
   if ! [ -z "$imageOverride" ]; then
      image=$imageOverride
      $iecho "Using image override"
      loadImage
      if ! [ "$?" = "0" ]; then
         iberr "fatal: the image override cannot be used"
         sed -i "s/imageOverride=$imageOverride/imageOverride=/g" data/$idol/idol.txt
         return 1
      fi
   else
      eventHandler
      if ! [ -f data/$idol/$event-recents.txt ]; then touch data/$idol/$event-recents.txt; fi
      $iecho "Event: $event"
      while :
      do
         checkImage
         loadImage
         if [ "$?" = "0" ]; then break; fi
         ((imageRetries+=1))
         if [ "$imageRetries" = "10" ]; then iberr "fatal: image retry limit reached"; return 1; fi
         iberr "warning: trying another image ($imageRetries/10)..."
      done
   fi
   if ! [ "$imgtype" = "mp4" ]; then
      postIdolPic
      if [ "$?" != "0" ]; then
         iberr "fatal: failed to post image!"
         return 1
      fi
   else
      if [ "$dryrun" = "0" ]; then
         postIdolVideo
         if [ "$?" != "0" ]; then
            iberr "fatal: failed to post video!"
            return 1
         fi
      else
         $iecho "skipping post because --dry-run or --no-post specified"
      fi
   fi
   if ! [ "$dryrun" = "2" ]; then
      $iecho "adding image to recents"
      incrementGlobalRecents
      if [ -z "$imageOverride" ]; then incrementRecents data/$idol/$event-recents.txt; fi
   fi
   if ! [ -z "$imageOverride" ] && ! [ "$dryrun" = "2" ] && ! [ "$clearImageOverride" = "0" ]; then updateIdolTxt imageOverride; fi
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
bap_loadSecrets data/$idol/secrets.env
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
if [ -z "$savedPDS" ]; then
   bap_findPDS $did
   if ! [ "$?" = 0 ]; then iberr "PDS lookup failure"; exit 1; fi
fi
loadConfig data/$idol/idol.txt
if [ -z "$idolTxtVersion" ] || [ "$idolTxtVersion" -lt "$internalIdolVer" ]; then refreshTxtCfg; fi
if [ "$2" = "post-timer" ]; then postTimer; fi
if [ "$2" = "post" ]; then postingLogic $3; fi
if [ "$2" = "repost" ]; then repostLogic $3 $4; fi
if [ -z "$2" ]; then iberr "no operation specified"; exit 1; fi
