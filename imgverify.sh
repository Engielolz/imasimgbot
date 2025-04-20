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

function fetchImageCache () {
   cachePath=
   if [ "$1" = "sub" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ ! -f "$cachePath/cache.txt" ]; then return 1; fi
   loadConfig $cachePath/cache.txt
   if [ ! -f "$cachePath/cache.$cacheimgtype" ]; then printcacheerr "cached image not found"; return 2; fi
   if [ "$cachehash" != "$(sha256sum $cachePath/cache.$cacheimgtype | awk '{print $1}')" ]; then printcacheerr "hash does not match cached image"; return 2; fi
   if [ "$orighash" != "$(sha256sum "$imagepath" | awk '{print $1}')" ]; then printcacheerr "hash does not match the image originally cached"; return 2; fi
   imagepath=$cachePath/cache.$cacheimgtype
   return 0
}

function prepImage () {
   bap_prepareImageForBluesky "$imagepath" >/dev/null
      if [ "$?" != "0" ]; then
         $printerrcmd "failed to prep image"
         if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
         return 1
      fi
         if [ "$1" = "clear" ]; then rm -f $bap_preparedImage; fi
}

function saveToImageCache () {
   if [ "$imgtype" = "mp4" ]; then return 0; fi
   cachePath=
   if [ "$1" = "sub" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ -f "$cachePath/cache.txt" ]; then return 0; fi # already cached
   prepImage || return 1
   mkdir -p $cachePath
   echo "orighash=$(sha256sum "$imagepath" | awk '{print $1}')" > $cachePath/cache.txt
   echo "cachehash=$(sha256sum $bap_preparedImage | awk '{print $1}')" >> $cachePath/cache.txt
   echo "cacheimgtype=${bap_preparedImage##*.}" >> $cachePath/cache.txt
   echo "cachemime=$bap_preparedMime" >> $cachePath/cache.txt
   echo "cachesize=$bap_preparedSize" >> $cachePath/cache.txt
   echo "cachewidth=$bap_imageWidth" >> $cachePath/cache.txt
   echo "cacheheight=$bap_imageHeight" >> $cachePath/cache.txt
   echo "bloblink=$bap_postedBlob" >> $cachePath/cache.txt
   cp -f $bap_preparedImage $cachePath/cache.${bap_preparedImage##*.}
   bloblink=$bap_postedBlob # don't run sed after image upload
   rm -f $bap_preparedImage 2> /dev/null
}

function checkImage () {
   if [ "$1" = "sub" ]; then printerrcmd=printsuberr; else printerrcmd=printerr; fi
   if [ -z "$imgtype" ]; then $printerrcmd "no imgtype"; return 1; fi
   if ! [ -f "$imagepath" ]; then $printerrcmd "no image"; return 1; fi
   if [ "$2" = "--scan" ] && ! [ "$imgtype" = "mp4" ]; then prepImage clear; if [ "$?" != "0" ]; then return 1; fi; fi
   return 0
}

function scanSubentries () {
   if ! [ -z "$imgtype" ]; then printerr "subentries do not post like entries"; fi
   if ! [ -f data/$idol/images/$image/subentries.txt ]; then printerr "no subentry list"; return 1; fi
   for i in $(seq 1 $(cat data/$idol/images/$image/subentries.txt | wc -l)); do
      subimage=$(cat data/$idol/images/$image/subentries.txt | sed -n $i'p')
      echo Checking subentry $subimage
      imgtype=
      subentries=
      loadConfig data/$idol/images/$image/$subimage/info.txt
      if ! [ "$?" = "0" ]; then printsuberr "no subentry data"; continue; fi
      if [ "$subentries" = "1" ]; then printsuberr "nested subentry not supported"; fi
      imagepath=data/$idol/images/$image/$subimage/image.$imgtype
      checkImage sub $(if [ "$scan" = "1" ]; then echo "--scan"; fi)
      if [ "$?" != "0" ]; then continue; fi
      if [ "$cacheverify" = "1" ] && ! [ "$imgtype" = "mp4" ]; then fetchImageCache sub; if [ "$?" = "2" ]; then rm -r $cachePath; fi; fi
      if [ "$scan" = "2" ]; then saveToImageCache sub; fi
   done
}

source bash-atproto/bash-atproto.sh && source bash-atproto/bap-bsky.sh
if ! [ "$?" = "0" ]; then loadFail; fi
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
      loadConfig data/$idol/images/$image/info.txt
      if ! [ "$?" = "0" ]; then printerr "no entry data"; continue; fi
      if [ "$subentries" = "1" ]; then scanSubentries; continue; fi
      if [ -f data/$idol/images/$image/subentries.txt ]; then printerr "subentries detected but not enabled (overwrite info.txt with subentries=1)"; fi
      imagepath="data/$idol/images/$image/image.$imgtype"
      checkImage main $(if [ "$scan" = "1" ]; then echo "--scan"; fi)
      if [ "$?" != "0" ]; then continue; fi
      if [ "$cacheverify" = "1" ] && ! [ "$imgtype" = "mp4" ]; then fetchImageCache; if [ "$?" = "2" ]; then rm -r $cachePath; fi; fi
      if [ "$scan" = "2" ]; then saveToImageCache; fi
   done
done

if [ -z "$errordata" ]; then echo "No entry errors encountered."
else
   >&2 echo "Entry errors encountered:"
   >&2 echo "$errordata"
fi

if [ ! -z "$cacheerrordata" ]; then
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
