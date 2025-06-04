#!/bin/bash
# SPDX-License-Identifier: MIT
internalIdolVer=5

function ibecho () {
   echo "$idol": "$@"
}

function iberr () {
   >&2 ibecho "$@"
}

function loadFail () {
   >&2 echo "Cannot load required dependency script"
   exit 127
}

function showHelp () {
   cat <<EOF
usage: ./idolbot.sh <idol> <command>
commands:
login      - specify a did/handle and app-password to generate secrets
             use --interactive instead of creds to log in interactively
logout     - close account session and remove secrets file
             append --force to local delete even if pds is unreachable
post       - normal behavior to post an image
             append --dry-run to not do anything
             append --no-post to not (re)post but still modify recent queues
repost     - repost another idol bot's post (specify uri and cid)
post-timer - post depending on the last post time (not meant for manual use)
EOF
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

# shellcheck disable=SC2015
source ./bash-atproto/bash-atproto.sh && source ./bash-atproto/bap-bsky.sh && source imgcache.sh || loadFail
if [ "$bap_internalVersion" != "3" ] || ! [ "$bap_internalMinorVer" -ge "3" ]; then >&2 echo "Incorrect bash-atproto version"; exit 1; fi
if [ "$bapBsky_internalVersion" != "1" ] || ! [ "$bapBsky_internalMinorVer" -ge "2" ]; then >&2 echo "Incorrect bap-bsky version"; exit 1; fi
bap_curlUserAgent="$bap_curlUserAgent imasimgbot/1.$internalIdolVer-$(git -c safe.directory="$(pwd)" describe --always --dirty) (+https://github.com/Engielolz/imasimgbot)"
bapBsky_allowLegacyPre2=0

# Check params
if [ -z "$1" ] || [ "$1" = "--help" ]; then showHelp; exit 1; fi

function refreshTxtCfg () {
   ibecho "updating idol.txt to new version"
   if [ -z "$clearImageOverride" ]; then clearImageOverride=1; fi
   if [ -z "$randomEventChance" ]; then randomEventChance=0; fi
   if [ -z "$postInterval" ]; then postInterval=4; fi
   if [ -z "$bdayInterval" ]; then bdayInterval=2; fi
   if [ -z "$globalQueueSize" ]; then globalQueueSize=48; fi
   if [ -z "$directVideoPosting" ]; then directVideoPosting=0; fi
   if [ -z "$imageCacheStrategy" ]; then imageCacheStrategy=0; fi
   if [ -z "$imageCacheLocation" ]; then imageCacheLocation=./data/$idol/cache; fi
   # shellcheck disable=SC2154
   cat >"data/$idol/idol.txt" <<EOF
# Version of this file. Don't touch this.
idolTxtVersion=$internalIdolVer
# Unix timestamp for next post. Don't touch this either.
nextPostTime=$nextPostTime

# Enter the name of an entry to post it instead of picking
imageOverride=$imageOverride
# Set this to 0 to always post the override (otherwise it's posted only once)
clearImageOverride=$clearImageOverride
# 1 in # chance to post from the random event
randomEventChance=$randomEventChance
# The random event
randomEventName=$randomEventName

# Post every # runs (one run is by default 15 minutes)
postInterval=$postInterval
# Date to run the birthday event (MMDD, always in JST)
birthday=$birthday
# postInterval on birthdays
bdayInterval=$bdayInterval

# The # latest used images will not be posted. Set to 0 to disable
globalQueueSize=$globalQueueSize
# If 1, post video via Lumi instead of to PDS
directVideoPosting=$directVideoPosting
# Set to 1 to use image caching or blob IDs with 2. Set to 0 to disable
imageCacheStrategy=$imageCacheStrategy
# Location of the image cache if enabled
imageCacheLocation=$imageCacheLocation
EOF
}

function sedTest () {
   # Is this GNU sed?
   if sed --help | grep "GNU" > /dev/null; then echo '0'
   # Do we have ed?
   elif command -v ed > /dev/null; then echo '1'
   # Use sed with diff-patch
   else echo '2'
   fi
}

function repText () {
   case "$(sedTest)" in
      0) sed -i "$1" "$2"; return $?;;
      1) echo ",$1; w" | tr \; '\012' | ed -s "$2"; return $?;;
      2) sed "$1" "$2" | diff -p "$2" | patch > /dev/null; return $?;;
   esac
}

function preText () {
   case "$(sedTest)" in
      0) sed -i "1s/^/$1\n/" "$2"; return $?;;
      1) printf '0a\n%s\n.\nw\n' "$1" | ed -s "$2"; return $?;;
      2) sed "1s/^/$1\n/" "$2" | diff -p "$2" | patch > /dev/null; return $?;;
   esac
}

function truText () {
   # shellcheck disable=SC2016
   case "$(sedTest)" in
      0) sed -i "$1,$ d" "$2"; return $?;;
      1) printf '%s,$d\nwq\n' "$1" | ed -s "$2" > /dev/null; return $?;;
      2) sed "$1,$ d" "$2" | diff -p "$2" | patch > /dev/null; return $?;;
   esac
}

function updateIdolTxt () {
   repText "s/$1=${!1}/$1=$2/g" "data/$idol/idol.txt"
}

function login () {
   if [ -z "$2" ]; then iberr "login params not specified"; return 1; fi
   bap_didInit "$1" || { iberr "did init failure"; return 1; }
   bap_findPDS "$savedDID" || { iberr "failed to resolve PDS"; return 1; }
   bap_getKeys "$savedDID" "$2" || { iberr "failed to log in"; return 1; }
   bap_saveSecrets "./data/$idol/secrets.env"
   return 0
}

function interactiveLogin () {
   local handle apppassword
   read -rp "$idol: Handle: " handle
   read -rsp "$idol: App Password: " apppassword
   login "$handle" "$apppassword"
   return $?
}

function checkRefresh () {
   if [ "$(date +%s)" -gt "$(( savedAccessExpiry - 300 ))" ]; then # refresh 5 minutes before expiry
      ibecho "Refreshing tokens"
      bap_refreshKeys || { iberr "fatal: refresh error"; return 1; }
      bap_saveSecrets "data/$idol/secrets.env"
      return 0
   fi
}

function repostLogic () {
   ibecho "Going to repost."
   checkRefresh || return $?
   ibecho "Reposting $1 with CID $2"
   # shellcheck disable=SC2015
   bapBsky_createRepost "$1" "$2" && ibecho "Repost succeeded." || { iberr "Error when trying to repost."; return 1; }
}

function incrementRecents () {
   if ! [ -s "$1" ]; then echo > "$1"; fi
   if [ "$2" = "--subimage" ]; then preText "$subimage" "$1"; else preText "$image" "$1"; fi
   return 0
}

function incrementGlobalRecents () {
   if ! [ -s "data/$idol/recents.txt" ]; then echo > "data/$idol/recents.txt"; fi
   preText "$image" "data/$idol/recents.txt"
   if [ -z "$globalQueueSize" ]; then globalQueueSize=24; fi
   ((globalQueueSize+=1))
   truText "$globalQueueSize" "data/$idol/recents.txt"
   return 0
}

function idolReposting () {
   ibecho "reposting for idols $otheridols"
   echo "$otheridols" | tr ',' '\n' | while read -r ridol; do
      env -i "$0" "$ridol" repost "$uri" "$cid"
   done
   return 0
}

function addPostTags () {
   if [ -n "$text" ]; then bapCYOR_str text "$text" || return $?; fi
   # shellcheck disable=SC2046
   if [ -n "$selflabel" ]; then bapBsky_cyorAddSelfLabels $(echo "$selflabel" | tr ',' ' ') || return $?; fi
   # shellcheck disable=SC2046
   if [ -n "$tags" ]; then bapBsky_cyorAddTags $(echo "$tags" | tr ',' ' ') || return $?; fi
   # shellcheck disable=SC2046
   if [ -n "$langs" ]; then bapBsky_cyorAddLangs $(echo "$langs" | tr ',' ' ') || return $?; fi
   return 0
}

function postIdolPic () {
   imageCaching=0
   if [ "$imageCacheStrategy" -ge "1" ]; then
      fetchImageCache
      case $? in
         0)
         imageCaching=1
         loadCachedImage
         ibecho "using cached image";;
         2)
         iberr "cached image data invalid, purging"
         rm -r "$cachePath";;
      esac
   fi
   if [ "$imageCaching" = "0" ]; then
      ibecho "preparing image"
      bapBsky_prepareImage "$imagepath" || { iberr "fatal: image prep failed"; if [ -f "$bap_preparedImage" ]; then rm -f "$bap_preparedImage"; fi; return 1; }
   fi
   if ! [ "$dryrun" = "0" ]; then rm "$bap_preparedImage"; fi
   if [ "$dryrun" = "0" ]; then
      checkRefresh || { rm -f "$bap_preparedImage"; return 1; }
      if [ "$imageCaching" = "0" ] || [ "$imageCacheStrategy" != "2" ] || [ -z "$bloblink" ]; then
         ibecho "uploading image to pds"
         bap_postBlobToPDS "$bap_preparedImage" "$bap_preparedMime" || { iberr "fatal: blob posting failed!"; if [ -f "$bap_preparedImage" ]; then rm -f "$bap_preparedImage"; fi; return 1; }
         # shellcheck disable=SC2119
         if [ "$imageCacheStrategy" != "0" ]; then saveToImageCache; fi
         rm "$bap_preparedImage"
      else ibecho "reusing cached blob id"
      fi
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   if [ "$dryrun" != "0" ] && [ -z "$bap_postedBlob" ]; then bap_postedBlob=dry-run bap_postedMime=$bap_preparedMime bap_postedSize=$bap_preparedSize; fi
   ibecho "posting image"
   bapBsky_cyorInit
   # this shouldn't fail but exit if it does
   bapBsky_cyorAddImage 0 "$bap_postedBlob" "$bap_postedMime" "$bap_postedSize" "$bap_imageWidth" "$bap_imageHeight" "$alt" || { iberr "fatal: image embed error!"; return 1; }
   addPostTags || { iberr "fatal: problem occurred adding tags!"; return 1; }
   if [ "$dryrun" != "0" ]; then ibecho "dry-run post JSON: $bap_cyorRecord"; return 0; fi
   bapBsky_submitPost || { iberr "fatal: image posting failed!"; return 1; }
   ibecho "image upload SUCCESS"
   if [ "$imageCacheStrategy" != "0" ] && [ -z "$bloblink" ]; then repText "s/bloblink=/bloblink=$bap_postedBlob/g" "$cachePath/cache.txt"; fi
   return 0
}

function postIdolVideo () {
   imageCaching=0
   if [ "$imageCacheStrategy" -ge "1" ]; then
      fetchImageCache
      case $? in
         0)
         imageCaching=1
         loadCachedImage
         ibecho "using cached video";;
         2)
         iberr "cached video data invalid, purging"
         rm -r "$cachePath";;
      esac
   fi
   if [ "$imageCaching" = "0" ]; then
      ibecho "preparing video"
      prepareVideo "$imagepath" || { iberr "fatal: video prep failed"; if [ -f "$bap_preparedImage" ]; then rm -f "$bap_preparedImage"; fi; return 1; }
   fi
   if ! [ "$dryrun" = "0" ]; then rm "$bap_preparedImage"; fi
   if [ "$dryrun" = "0" ]; then
      checkRefresh || { rm -f "$bap_preparedImage"; return 1; }
      if [ "$imageCaching" = "0" ] || [ "$imageCacheStrategy" != "2" ] || [ -z "$bloblink" ]; then
         ibecho "uploading video to pds"
         if [ "$directVideoPosting" = "1" ]; then videoUploadCMD=bapBsky_prepareVideo; else videoUploadCMD=bapBsky_prepareVideoIndirect; fi
         $videoUploadCMD "$bap_preparedImage" "video/mp4" || { iberr "fatal: video upload failed!"; rm "$bap_preparedImage"; return 1; }
         # shellcheck disable=SC2119
         if [ "$imageCacheStrategy" != "0" ]; then saveToImageCache; fi
         rm "$bap_preparedImage"
      else ibecho "reusing cached blob id"
      fi
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   if [ "$dryrun" != "0" ] && [ -z "$bap_postedBlob" ]; then bap_postedBlob=dry-run bap_postedMime=$bap_preparedMime bap_postedSize=$bap_preparedSize; fi
   ibecho "posting video"
   bapBsky_cyorInit
   # this shouldn't fail but exit if it does
   bapBsky_cyorAddVideo "$bap_postedBlob" "$bap_postedSize" "$bap_imageWidth" "$bap_imageHeight" "$alt" || { iberr "fatal: video embed error!"; return 1; }
   addPostTags || { iberr "fatal: problem occurred adding tags!"; return 1; }
   if [ "$dryrun" != "0" ]; then ibecho "dry-run post JSON: $bap_cyorRecord"; return 0; fi
   bapBsky_submitPost || { iberr "fatal: video posting failed!"; return 1; }
   ibecho "video upload SUCCESS (may take time to process)"
   if [ "$imageCacheStrategy" != "0" ] && [ -z "$bloblink" ]; then repText "s/bloblink=/bloblink=$bap_postedBlob/g" "$cachePath/cache.txt"; fi
   return 0
}



function eventHandler () {
   local iter
   if [[ -f data/events.txt ]]; then while IFS= read -r line; do
      if [[ $line = \#* ]] || [ -z "$line" ]; then continue; fi
      iter=2
      while :
      do
         if [ -z "$(echo "$line" | cut -d ',' -f $iter)" ]; then break; fi
         if [ "$(date +%m%d)" = "$(echo "$line" | cut -d ',' -f $iter)" ]; then event="$(echo "$line" | cut -d ',' -f 1)"; break 2; fi
         ((iter++))
      done
   done < "data/events.txt"
   fi
   if [ "$(TZ=Asia/Tokyo date +%m%d)" = "$birthday" ]; then event=birthday; fi
   if  [ "$randomEventChance" != "0" ] && [ $((RANDOM % randomEventChance)) = "0" ]; then event=$randomEventName; fi
   if [ -z "$event" ] || ! [ -f "data/$idol/images/$event.txt" ]; then event=regular; fi
}

function pickImage () {
   echo "$images" | sed -n $((1 + RANDOM % $1 ))'p'
}

function checkImage () {
   local recentsFile=data/$idol/recents.txt
   local eventRecentsFile=data/$idol/$event-recents.txt
   local eventFile=data/$idol/images/$event.txt
   images=$(grep -xvf "$recentsFile" -f "$eventRecentsFile" "$eventFile")
   if [ -z "$images" ]; then
      ibecho "resetting recents queue for $event"
      echo > "$eventRecentsFile"
      images=$(grep -xvf "$recentsFile" -f "$eventRecentsFile" "$eventFile")
   fi
   if ! grep -qxvf "$recentsFile" "$eventFile"; then
      iberr "warning: the global recents queue is too big for the event $event"
      iberr "hint: in idol.txt, set globalQueueSize to a lower value"
      images=$(grep -xvf "$eventRecentsFile" "$eventFile")
   fi
   if [ -z "$images" ]; then iberr "error: no valid image entries"; return 1; fi
   image=$(pickImage "$(echo "$images" | wc -l)")
   imagedir="data/$idol/images/$image"
   ibecho "picked entry $image"
}

function iterateSubentries () {
   images=$(grep -xvf "$imagedir/subentry-recents.txt" "$imagedir/subentries.txt")
   if [ -z "$images" ]; then
      ibecho "resetting subentry recents queue for $image"
      if ! [ -s "$imagedir/subentry-recents.txt" ]; then echo > "$imagedir/subentry-recents.txt"; fi
      truText 2 "$imagedir/subentry-recents.txt"
      images=$(grep -xvf "$imagedir/subentry-recents.txt" "$imagedir/subentries.txt")
   fi
   if [ -z "$images" ]; then iberr "error: no valid image subentries"; return 1; fi
   subimage=$(pickImage "$(echo "$images" | wc -l)")
   ibecho "picked subentry $subimage"
}

function loadImage () {
   # clean in case there's been failures
   imgtype='' alt='' otheridols='' subentries='' subimage='' text='' selflabel=''
   loadConfig "$imagedir/info.txt" || {
      iberr "fatal: the entry data for $image is missing"
      iberr "hint: if the above line is broken, it may be encoded in windows format"
      return 1
   }
   if [ "$subentries" = "1" ]; then
      iterateSubentries
      loadConfig "$imagedir/$subimage/info.txt" || { iberr "error reading data for $subimage"; return 1; }
      imagepath=$imagedir/$subimage/image.$imgtype
   else
      imagepath=$imagedir/image.$imgtype
   fi
   if ! [ -f "$imagepath" ]; then iberr "fatal: image $imagepath does not exist"; return 1; fi
   ibecho "location: $imagepath"
   ibecho "alt text: $alt"
   if [ -n "$text" ]; then ibecho "entry has post text: $text"; fi
   if [ -n "$selflabel" ]; then ibecho "entry has self-labels: $selflabel"; fi
   if [ -n "$tags" ]; then ibecho "entry has tags: $tags"; fi
   if [ -n "$langs" ]; then ibecho "entry has post languages: $langs"; fi
   if [ -n "$otheridols" ]; then ibecho "entry has other idols: $otheridols"; fi
   return 0
}

function getPostTime () {
   echo $(($(date +%s) + (($1 * $2) - $(date +%s) % ($1 * $2))))
}

function postTimer () {
   if [ -z "$svcInterval" ]; then iberr "error: timer not available; svcInterval not set"; return 1; fi
   # if not next post time or postinterval negative, return and do nothing
   if [ "$nextPostTime" -gt "$(date +%s)" ] || [ "$postInterval" -lt "0" ]; then return 0; fi
   postingLogic || return $?
   if [ "$(TZ=Asia/Tokyo date +%m%d)" = "$birthday" ]; then updateIdolTxt nextPostTime "$(getPostTime "$bdayInterval" "$svcInterval")"; else
   updateIdolTxt nextPostTime  "$(getPostTime "$postInterval" "$svcInterval")"; fi
   return 0
}

function postingLogic () {
   dryrun=0
   if [ "$1" = "--no-post" ]; then dryrun=1; fi
   if [ "$1" = "--dry-run" ]; then dryrun=2; fi
   if [ -n "$imageOverride" ]; then
      image=$imageOverride
      imagedir=data/$idol/images/$image
      ibecho "Using image override"
      loadImage || {
         iberr "fatal: the image override cannot be used"
         repText "s/imageOverride=$imageOverride/imageOverride=/g" "data/$idol/idol.txt"
         return 1
      }
   else
      eventHandler
      if ! [ -f "data/$idol/$event-recents.txt" ]; then touch "data/$idol/$event-recents.txt"; fi
      ibecho "Event: $event"
      while :
      do
         checkImage
         loadImage && break
         ((imageRetries+=1))
         if [ "$imageRetries" = "10" ]; then iberr "fatal: image retry limit reached"; return 1; fi
         iberr "warning: trying another image ($imageRetries/10)..."
      done
   fi
   if [ "$imgtype" = "gif" ] && [ "$(isAniGIF "$imagepath")" -ge "2" ] || [ "$imgtype" = "mp4" ]; then
      postIdolVideo || { iberr "fatal: failed to post video!"; return 1; }
   else
      postIdolPic || { iberr "fatal: failed to post image!"; return 1; }
   fi
   if ! [ "$dryrun" = "2" ]; then
      ibecho "adding image to recents"
      incrementGlobalRecents
      if [ -z "$imageOverride" ]; then incrementRecents "data/$idol/$event-recents.txt"; fi
      if [ "$subentries" = "1" ]; then incrementRecents "data/$idol/images/$image/subentry-recents.txt" --subimage; fi
   fi
   if [ -n "$imageOverride" ] && [ "$dryrun" != "2" ] && [ "$clearImageOverride" != "0" ]; then updateIdolTxt imageOverride; fi
   if [ -n "$otheridols" ];  then
      if [ "$dryrun" = "0" ]; then idolReposting
      else ibecho "not reposting because --dry-run or --no-post specified"; fi
   fi
   return 0
}

if ! [ -d "./data/$1" ]; then >&2 echo "idolbot: No such idol: $1"; exit 1; fi

idol=$1

if [ ! -f "data/$idol/secrets.env" ]; then
   if ! [ "$2" = "login" ]; then iberr "you need to login first."; exit 1; fi
   if ! [ "$3" = "--interactive" ]; then
      login "$3" "$4"
   else
      interactiveLogin
   fi
   exit $?
fi
bap_loadSecrets "data/$idol/secrets.env" || { iberr "error loading secrets"; exit 1; }

if [ "$2" = "login" ]; then
   if [ "$3" = "--force" ]; then
      login "$4" "$5"
      exit $?
   else
      iberr "you are already logged in. Pass --force to log in anyway"
      exit 2
   fi
fi

if [ "$2" = "logout" ]; then
   bap_closeSession > /dev/null || if [ "$3" != "--force" ]; then exit 1; fi
   rm "data/$idol/secrets.env"
   exit $?
fi

loadConfig "data/$idol/idol.txt"
if [ -z "$idolTxtVersion" ] || [ "$idolTxtVersion" -lt "$internalIdolVer" ]; then refreshTxtCfg; fi
if [ "$2" = "post-timer" ]; then postTimer; fi
if [ "$2" = "post" ]; then postingLogic "$3"; fi
if [ "$2" = "repost" ]; then repostLogic "$3" "$4"; fi
if [ -z "$2" ]; then iberr "no operation specified"; exit 1; fi
