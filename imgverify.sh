#!/bin/bash
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

function loadConfig () {
   if [[ -f $1 ]]; then while IFS= read -r line; do
      if [[ $line = \#* ]] || [ -z "$line" ]; then continue; fi
      declare -g "$line"
   done < "$1"
   return 0
   else return 1
   fi
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
      if [ -z "$imgtype" ]; then printsuberr "no imgtype"; continue; fi
      if ! [ -f "data/$idol/images/$image/$subimage/image.$imgtype" ]; then printsuberr "no image"; continue; fi
      if [ "$scan" = "1" ] && ! [ "$imgtype" = "mp4" ]; then
         bap_prepareImageForBluesky "data/$idol/images/$image/$subimage/image.$imgtype" >/dev/null 2>&1
         if [ "$?" != "0" ]; then
            printsuberr "failed to prep image"
            if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
         fi
         rm -f $bap_preparedImage
      fi
   done
}

source bash-atproto.sh
if ! [ "$?" = "0" ]; then loadFail; fi
event=$1
scan=0
errordata=
if [ -z "$1" ]; then event=regular; fi
if [ "$1" = "--scan-image" ]; then scan=1; event=regular; fi
if [ "$2" = "--scan-image" ]; then scan=1; fi

for i in $(seq 1 $(cat data/idols.txt | wc -l)); do
   idol=$(cat data/idols.txt | sed -n $i'p')
   echo "Checking image data for $idol"
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
      if [ -z "$imgtype" ]; then printerr "no imgtype"; continue; fi
      if ! [ -f "data/$idol/images/$image/image.$imgtype" ]; then printerr "no image"; continue; fi
      if [ "$scan" = "1" ] && ! [ "$imgtype" = "mp4" ]; then
         bap_prepareImageForBluesky "data/$idol/images/$image/image.$imgtype" >/dev/null 2>&1
         if [ "$?" != "0" ]; then
            printerr "failed to prep image"
            if [ -f $bap_preparedImage ]; then rm -f $bap_preparedImage; fi
         fi
         rm -f $bap_preparedImage
      fi
   done
done

if [ -z "$errordata" ]; then echo "No errors encountered."
else
   >&2 echo "Errors encountered:"
   >&2 echo "$errordata"
fi
