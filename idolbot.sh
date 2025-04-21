#!/bin/bash
# SPDX-License-Identifier: MIT
internalIdolVer=4
svcInterval=900 # must match postInterval in imasimgbot.sh

function iberr () {
   >&2 $iecho $*
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

source ./bash-atproto/bash-atproto.sh && source ./bash-atproto/bap-bsky.sh
if ! [ "$?" = "0" ]; then loadFail; fi
bap_curlUserAgent="$bap_curlUserAgent imasimgbot/1.$internalIdolVer-$(git -c safe.directory=$(pwd) describe --always --dirty) (+https://github.com/Engielolz/imasimgbot)"

# Check params
if [ -z "$1" ] || [ "$1" = "--help" ]; then showHelp; exit 1; fi

function refreshTxtCfg () {
   $iecho "updating idol.txt to new version"
   if [ -z "$postInterval" ]; then postInterval=4; fi
   if [ -z "$globalQueueSize" ]; then globalQueueSize=48; fi
   if [ -z "$clearImageOverride" ]; then clearImageOverride=1; fi
   if [ -z "$directVideoPosting" ]; then directVideoPosting=0; fi
   if [ -z "$imageCacheStrategy" ]; then imageCacheStrategy=0; fi
   if [ -z "$imageCacheLocation" ]; then imageCacheLocation=./data/$idol/cache; fi
   cat >data/$idol/idol.txt <<EOF
# Version of this file. Don't touch this.
idolTxtVersion=$internalIdolVer
# Unix timestamp for next post. Don't touch this either.
nextPostTime=$nextPostTime

# Enter the name of an entry to post it instead of picking
imageOverride=$imageOverride
# Set this to 0 to always post the override (otherwise it's posted only once)
clearImageOverride=$clearImageOverride

# Date to run the birthday event (MMDD, always in JST)
birthday=$birthday
# Post every # runs (one run is by default 15 minutes)
postInterval=$postInterval
# The # latest used images will not be posted. Set to 0 to disable
globalQueueSize=$globalQueueSize
# If 1, post video via Bluesky instead of to PDS
directVideoPosting=$directVideoPosting
# Set to 1 to use image caching or blob IDs with 2. Set to 0 to disable
imageCacheStrategy=$imageCacheStrategy
# Location of the image cache if enabled
imageCacheLocation=$imageCacheLocation
EOF
}

function updateIdolTxt () {
   sed -i "s/$1=${!1}/$1=$2/g" data/$idol/idol.txt
}

function login () {
   if [ -z "$2" ]; then iberr "login params not specified"; return 1; fi
   bap_didInit $1
   if ! [ "$?" = "0" ]; then iberr "did init failure"; return 1; fi
   bap_findPDS $savedDID
   if ! [ "$?" = "0" ]; then iberr "failed to resolve PDS"; return 1; fi
   bap_getKeys $savedDID $2
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
   bap_findPDS $savedDID
   if ! [ "$?" = "0" ]; then iberr "failed to resolve PDS"; return 1; fi
   bap_getKeys $savedDID $apppassword
   if ! [ "$?" = "0" ]; then iberr "failed to log in"; return 1; fi
   bap_saveSecrets ./data/$idol/secrets.env
   apppassword=
   return 0
}

function checkRefresh () {
   if [ "$(date +%s)" -gt "$(( $savedAccessExpiry - 300 ))" ]; then # refresh 5 minutes before expiry
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
   bapBsky_createRepost $1 $2
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
   if [ "$2" = "--subimage" ]; then sed -i "1s/^/$subimage\n/" $1; else sed -i "1s/^/$image\n/" $1; fi
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

function fetchImageCache () {
   if [ "$subentries" = "1" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ ! -f "$cachePath/cache.txt" ]; then return 1; fi
   loadConfig $cachePath/cache.txt
   if [ ! -f "$cachePath/cache.$cacheimgtype" ]; then iberr "cached image not found"; return 2; fi
   if [ "$cachehash" != "$(sha256sum $cachePath/cache.$cacheimgtype | awk '{print $1}')" ]; then iberr "hash does not match cached image"; return 2; fi
   if [ "$orighash" != "$(sha256sum $imagepath | awk '{print $1}')" ]; then iberr "hash does not match the image originally cached"; return 2; fi
   imagepath=$cachePath/cache.$cacheimgtype
   return 0
}

function loadCachedImage () {
   # expects fetchImageCache to be run beforehand
   # for bap_postBlobToPDS
   bap_preparedImage=/tmp/idolbot-$(uuidgen).$cacheimgtype
   if [ "$imageCacheStrategy" = "1" ] || [ -z "$bloblink" ]; then cp $cachePath/cache.$cacheimgtype $bap_preparedImage; fi
   bap_preparedMime=$cachemime
   # for bap_postImageToBluesky
   bap_postedMime=$cachemime
   bap_postedBlob=$bloblink
   bap_postedSize=$cachesize
   bap_imageWidth=$cachewidth
   bap_imageHeight=$cacheheight
}

function saveToImageCache () {
   if [ "$subentries" = "1" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ -f "$cachePath/cache.txt" ] && [ "$1" != "--force" ]; then return 0; fi # already cached
   mkdir -p $cachePath
   echo "orighash=$(sha256sum $imagepath | awk '{print $1}')" > $cachePath/cache.txt
   echo "cachehash=$(sha256sum $bap_preparedImage | awk '{print $1}')" >> $cachePath/cache.txt
   echo "cacheimgtype=${bap_preparedImage##*.}" >> $cachePath/cache.txt
   echo "cachemime=$bap_postedMime" >> $cachePath/cache.txt
   echo "cachesize=$bap_postedSize" >> $cachePath/cache.txt
   echo "cachewidth=$bap_imageWidth" >> $cachePath/cache.txt
   echo "cacheheight=$bap_imageHeight" >> $cachePath/cache.txt
   echo "bloblink=$bap_postedBlob" >> $cachePath/cache.txt
   cp -f $bap_preparedImage $cachePath/cache.${bap_preparedImage##*.}
   bloblink=$bap_postedBlob # don't run sed after image upload
}

function postIdolPic () {
   imageCaching=0
   if [ "$imageCacheStrategy" -ge "1" ]; then
      fetchImageCache
      case $? in
         0)
         imageCaching=1
         loadCachedImage
         $iecho "using cached image";;
         2)
         iberr "cached image data invalid, purging"
         rm -r $cachePath;;
      esac
   fi
   if [ "$imageCaching" = "0" ]; then
      $iecho "preparing image"
      bapBsky_prepareImage $imagepath
      if [ "$?" != "0" ]; then
         iberr "fatal: image prep failed!"
         if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
         return 1
      fi
   fi
   if ! [ "$dryrun" = "0" ]; then rm $bap_preparedImage; fi
   if [ "$dryrun" = "0" ]; then
      checkRefresh
      if [ "$?" != "0" ]; then rm -f $bap_preparedImage; return 1; fi
      if [ "$imageCacheStrategy" != "2" ] || [ -z "$bloblink" ]; then
         $iecho "uploading image to pds"
         bap_postBlobToPDS $bap_preparedImage $bap_preparedMime
         if [ "$?" != "0" ]; then
            iberr "fatal: blob posting failed!"
            if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
            return 1
         fi
         if [ "$imageCacheStrategy" != "0" ]; then saveToImageCache; fi
         rm $bap_preparedImage
      else $iecho "reusing cached blob id"
      fi
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   if [ "$dryrun" != "0" ] && [ -z "$bap_postedBlob" ]; then bap_postedBlob=dry-run bap_postedMime=$bap_preparedMime bap_postedSize=$bap_preparedSize; fi
   $iecho "posting image"
   bapBsky_cyorInit
   bapBsky_cyorAddImage 0 $bap_postedBlob $bap_postedMime $bap_postedSize $bap_imageWidth $bap_imageHeight "$alt"
   if [ ! -z "$text" ]; then bapCYOR_str text "$text"; fi
   if [ ! -z "$selflabel" ]; then bapBsky_cyorAddLabel 0 $selflabel; fi
   if [ "$dryrun" != "0" ]; then $iecho "dry-run post JSON: $bap_cyorRecord"; return 0; fi
   bapBsky_submitPost
   if [ "$?" != "0" ]; then
      iberr "fatal: image posting failed!"
      return 1
   fi
   $iecho "image upload SUCCESS"
   if [ "$imageCacheStrategy" != "0" ] && [ -z "$bloblink" ]; then sed -i "s/bloblink=/bloblink=$bap_postedBlob/g" $cachePath/cache.txt; fi
   return 0
}

function postIdolVideo () {
   checkRefresh
   if [ "$?" != "0" ]; then return 1; fi
   if [ "$directVideoPosting" = "1" ]; then videoUploadCMD=bapBsky_prepareVideo; else
      bapBsky_checkVideo "$imagepath" || return $?
      videoUploadCMD=bap_postBlobToPDS
      bap_imageWidth=$(exiftool -ImageWidth -s3 $imagepath)
      if ! [ "$?" = "0" ]; then iberr "fatal: exiftool failed!"; return 1; fi
      bap_imageHeight=$(exiftool -ImageHeight -s3 $imagepath)
      if ! [ "$?" = "0" ]; then iberr "fatal: exiftool failed!"; return 1; fi
   fi
   $iecho "uploading video to pds"
   $videoUploadCMD $imagepath "video/mp4"
   if [ "$?" != "0" ]; then
      iberr "fatal: video upload failed!"
      return 1
   fi
   # check preparedMime/postedMime and preparedSize/postedSize
   $iecho "posting video"
   bapBsky_postVideo $bap_postedBlob $bap_postedSize $bap_imageWidth $bap_imageHeight "$alt"
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

function iterateSubentries () {
   images=$(grep -xvf data/$idol/images/$image/subentry-recents.txt data/$idol/images/$image/subentries.txt)
   if [ -z "$images" ]; then
      $iecho "resetting subentry recents queue for $image"
      echo > data/$idol/images/$image/subentry-recents.txt
      images=$(grep -xvf data/$idol/images/$image/subentry-recents.txt data/$idol/images/$image/subentries.txt)
   fi
   if [ -z "$images" ]; then iberr "error: no valid image subentries"; return 1; fi
   subimage=$(pickImage $(echo "$images" | wc -l))
   $iecho "picked subentry $subimage"
}

function loadImage () {
   # clean in case there's been failures
   imgtype= alt= otheridols= subentries= subimage= text= selflabel=
   loadConfig data/$idol/images/$image/info.txt
   if ! [ "$?" = "0" ]; then
      iberr "fatal: the entry data for $image is missing"
      iberr "hint: if the above line is broken, it may be encoded in windows format"
      return 1
   fi
   if [ "$subentries" = "1" ]; then
      iterateSubentries
      loadConfig data/$idol/images/$image/$subimage/info.txt
      if ! [ "$?" = 0 ]; then iberr "error reading data for $subimage"; return 1; fi
      imagepath=data/$idol/images/$image/$subimage/image.$imgtype
   else
      imagepath=data/$idol/images/$image/image.$imgtype
   fi
   if ! [ -f $imagepath ]; then iberr "fatal: image $imagepath does not exist"; return 1; fi
   $iecho "location: $imagepath"
   $iecho "alt text: $alt"
   if [ ! -z "$text" ]; then $iecho "entry has post text: $text"; fi
   if [ ! -z "$selflabel" ]; then $iecho "entry has a self-label: $selflabel"; fi
   if [ ! -z "$otheridols" ]; then $iecho "entry has other idols: $otheridols"; fi
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
      if [ "$subentries" = "1" ]; then incrementRecents data/$idol/images/$image/subentry-recents.txt --subimage; fi
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
if [ ! -f "data/$idol/secrets.env" ]; then
   if ! [ "$2" = "login" ]; then iberr "you need to login first."; exit 1; fi
   if ! [ "$3" = "--interactive" ]; then
      login $3 $4
   else
      interactiveLogin
   fi
   exit $?
fi
bap_loadSecrets data/$idol/secrets.env
if [ "$?" != "0" ]; then iberr "error loading secrets"; exit 1; fi

if [ "$2" = "login" ]; then
   if [ "$3" = "--force" ]; then
      login $4 $5
      exit $?
   else
      iberr "you are already logged in. Pass --force to log in anyway"
      exit 2
   fi
fi

if [ "$2" = "logout" ]; then
   bap_closeSession > /dev/null
   if [ "$?" != "0" ] && [ "$3" != "--force" ]; then exit 1; fi
   rm data/$idol/secrets.env
   exit $?
fi

loadConfig data/$idol/idol.txt
if [ -z "$idolTxtVersion" ] || [ "$idolTxtVersion" -lt "$internalIdolVer" ]; then refreshTxtCfg; fi
if [ "$2" = "post-timer" ]; then postTimer; fi
if [ "$2" = "post" ]; then postingLogic $3; fi
if [ "$2" = "repost" ]; then repostLogic $3 $4; fi
if [ -z "$2" ]; then iberr "no operation specified"; exit 1; fi
