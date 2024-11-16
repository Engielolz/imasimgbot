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
      loadSecrets data/$idol/images/$image/info.txt
      if ! [ "$?" = "0" ]; then printerr "no image data"; continue; fi
      if [ -z "$imgtype" ]; then printerr "no imgtype"; continue; fi
      if ! [ -f "data/$idol/images/$image/image.$imgtype" ]; then printerr "no image"; continue; fi
      if [ "$scan" = "1" ] && ! [ "$imgtype" = "mp4" ]; then
         prepareImageForBluesky "data/$idol/images/$image/image.$imgtype" >/dev/null 2>&1
         if [ "$?" != "0" ]; then
            printerr "failed to prep image"
            if [ -f $preparedImage ]; then rm -f $preparedImage; fi
         fi
         rm -f $preparedImage
      fi
   done
done

if [ -z "$errordata" ]; then echo "No errors encountered."
else
   >&2 echo "Errors encountered:"
   >&2 echo "$errordata"
fi
