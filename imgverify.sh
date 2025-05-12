#!/bin/bash
# SPDX-License-Identifier: MIT
function loadFail () {
   echo "Required scripts not found!"
   exit 127
}

function printerr () {
   >&2 echo "in $image: $1"
   errordata+="$idol/$event $image: $1
"
}

function printsuberr () {
   >&2 echo "in $image, subentry $subimage: $1"
   errordata+="$idol/$event $image/$subimage: $1
"
}

function printcacheerr () {
   >&2 echo "cache error $cachePath: $1"
   cacheerrordata+="$idol/$event $cachePath: $1
"
}

function loadConfig () {
   if [[ -f $1 ]]; then while IFS= read -r line; do
      if [[ $line = \#* ]] || [ -z "$line" ]; then continue; fi
      declare -g "$line"
   done < "$1"
   return 0
   else return 1
   fi
}

function prepImage () {
   bapBsky_prepareImage "$imagepath" >/dev/null || { $printerrcmd "failed to prep image"; if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi; return 1; }
   if [ "$1" = "clear" ]; then rm -f $bap_preparedImage; fi
}

function checkImage () {
   if [ "$1" = "sub" ]; then printerrcmd=printsuberr; else printerrcmd=printerr; fi
   if [ -z "$imgtype" ]; then $printerrcmd "no imgtype"; return 1; fi
   if ! [ -f "$imagepath" ]; then $printerrcmd "no image"; return 1; fi
   if [ "$2" = "--scan" ] && ! [ "$imgtype" = "mp4" ]; then prepImage clear; if [ "$?" != "0" ]; then return 1; fi; fi
   return 0
}

function scanSubentries () {
   if [ -n "$imgtype" ]; then printerr "subentries do not post like entries"; fi
   if ! [ -f data/$idol/images/$image/subentries.txt ]; then printerr "no subentry list"; return 1; fi
   for i in $(seq 1 $(cat data/$idol/images/$image/subentries.txt | wc -l)); do
      subimage=$(cat data/$idol/images/$image/subentries.txt | sed -n $i'p')
      echo Checking subentry $subimage
      imgtype=
      subentries=
      loadConfig data/$idol/images/$image/$subimage/info.txt || { printsuberr "no subentry data"; continue; }
      if [ "$subentries" = "1" ]; then printsuberr "nested subentry not supported"; fi
      imagepath=data/$idol/images/$image/$subimage/image.$imgtype
      checkImage sub $(if [ "$scan" = "1" ]; then echo "--scan"; fi) || continue
      if [ "$cacheverify" = "1" ] && ! [ "$imgtype" = "mp4" ]; then subentries=1 fetchImageCache; if [ "$?" = "2" ]; then rm -r $cachePath; fi; fi
      if [ "$scan" = "2" ]; then
         if [ "$imgtype" = "mp4" ]; then continue; fi
         prepImage || continue
         subentries=1 saveToImageCache
         rm -f $bap_preparedImage 2> /dev/null
      fi
   done
}

source bash-atproto/bash-atproto.sh && source bash-atproto/bap-bsky.sh && source imgcache.sh || loadFail
if [ "$bap_internalVersion" != "3" ] || ! [ "$bap_internalMinorVer" -ge "0" ]; then >&2 echo "Incorrect bash-atproto version"; return 1; fi
if [ "$bapBsky_internalVersion" != "1" ] || ! [ "$bapBsky_internalMinorVer" -ge "0" ]; then >&2 echo "Incorrect bap-bsky version"; return 1; fi
event=$1
scan=0
errordata=
cacheerrordata=
# This system is ugly
if [ -z "$1" ]; then event=regular; fi
if [ "$1" = "--scan-image" ]; then scan=1; event=regular; fi
if [ "$2" = "--scan-image" ]; then scan=1; fi
if [ "$1" = "--build-cache" ]; then scan=2; event=regular; fi
if [ "$2" = "--build-cache" ]; then scan=2; fi
if [ "$1" = "--verify-cache" ]; then cacheverify=1; event=regular; fi
if [ "$2" = "--verify-cache" ]; then cacheverify=1; fi
if [ "$1" = "--repair-cache" ]; then cacheverify=1; scan=2; event=regular; fi
if [ "$2" = "--repair-cache" ]; then cacheverify=1; scan=2; fi

case $scan in
   1)
      echo "Image scanning is on. This will take a while";;
   2)
      echo "Cache building is on. This will take a while";;
esac

for i in $(seq 1 $(cat data/idols.txt | wc -l)); do
   idol=$(cat data/idols.txt | sed -n $i'p')
   echo "Checking image data for $idol"
   loadConfig data/$idol/idol.txt
   if [ ! -f "data/$idol/images/$event.txt" ]; then echo "$idol has no data for $event, skipping"; continue; fi
   echo $event has $(cat data/$idol/images/$event.txt | wc -l) entries
   for i in $(seq 1 $(cat data/$idol/images/$event.txt | wc -l)); do
      image=$(cat data/$idol/images/$event.txt | sed -n $i'p')
      echo Checking entry $image
      imgtype=
      subentries=
      loadConfig data/$idol/images/$image/info.txt || { printerr "no entry data"; continue; }
      if [ "$subentries" = "1" ]; then scanSubentries; continue; fi
      if [ -f data/$idol/images/$image/subentries.txt ]; then printerr "subentries detected but not enabled (overwrite info.txt with subentries=1)"; fi
      imagepath="data/$idol/images/$image/image.$imgtype"
      checkImage main $(if [ "$scan" = "1" ]; then echo "--scan"; fi) || continue
      if [ "$cacheverify" = "1" ] && ! [ "$imgtype" = "mp4" ]; then fetchImageCache; if [ "$?" = "2" ]; then rm -r $cachePath; fi; fi
      if [ "$scan" = "2" ]; then
         if [ "$imgtype" = "mp4" ]; then continue; fi
         prepImage || continue
         saveToImageCache
         rm -f $bap_preparedImage 2> /dev/null
      fi
   done
done

if [ -z "$errordata" ]; then echo "No entry errors encountered."
else
   >&2 echo "Entry errors encountered:"
   >&2 echo "$errordata"
fi

if [ -n "$cacheerrordata" ]; then
   if [ "$scan" = "2" ]; then
      >&2 echo "imgverify found errors in the cached files and has regenerated them."
      >&2 echo "No further action is required."
   else
      >&2 echo "imgverify found errors in the following cached files and has removed them."
      >&2 echo "Please regenerate them with the --build-cache or --repair-cache parameters."
   fi
   >&2 echo "$cacheerrordata"
elif [ "$cacheverify" = "1" ]; then
   echo "imgverify has checked the cache and found no problems."
   echo "No further action is required."
fi
