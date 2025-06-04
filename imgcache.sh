#!/bin/bash
# SPDX-License-Identifier: MIT

function printcacheerr () {
   >&2 echo "cache error $cachePath: $1"
   cacheerrordata+="$idol/$event $cachePath: $1
"
}

function fetchImageCache () {
   cachePath= #imgverify
   if [ "$subentries" = "1" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ ! -f "$cachePath/cache.txt" ]; then return 1; fi
   loadConfig "$cachePath/cache.txt"
   if [ ! -f "$cachePath/cache.$cacheimgtype" ]; then printcacheerr "cached image not found"; return 2; fi
   if [ "$cachehash" != "$(sha256sum "$cachePath/cache.$cacheimgtype" | awk '{print $1}')" ]; then printcacheerr "hash does not match cached image"; return 2; fi
   if [ "$orighash" != "$(sha256sum "$imagepath" | awk '{print $1}')" ]; then printcacheerr "hash does not match the image originally cached"; return 2; fi
   imagepath=$cachePath/cache.$cacheimgtype
   return 0
}

function loadCachedImage () { #idolbot
   # expects fetchImageCache to be run beforehand
   # for bap_postBlobToPDS
   bap_preparedImage=/tmp/idolbot-$(uuidgen).$cacheimgtype
   if [ "$imageCacheStrategy" = "1" ] || [ -z "$bloblink" ]; then cp "$cachePath/cache.$cacheimgtype" "$bap_preparedImage"; fi
   bap_preparedMime=$cachemime
   # for bap_postImageToBluesky
   bap_postedMime=$cachemime
   bap_postedBlob=$bloblink
   bap_postedSize=$cachesize
   bap_imageWidth=$cachewidth
   bap_imageHeight=$cacheheight
}

function saveToImageCache () {
   cachePath= #imgverify
   if [ "$subentries" = "1" ]; then cachePath=$imageCacheLocation/$image-$subimage; else cachePath=$imageCacheLocation/$image; fi
   if [ -f "$cachePath/cache.txt" ]; then return 0; fi # already cached
   mkdir -p "$cachePath"
   {
   echo "orighash=$(sha256sum "$imagepath" | awk '{print $1}')"
   echo "cachehash=$(sha256sum "$bap_preparedImage" | awk '{print $1}')"
   echo "cacheimgtype=${bap_preparedImage##*.}"
   echo "cachemime=$bap_preparedMime"
   echo "cachesize=$bap_preparedSize"
   echo "cachewidth=$bap_imageWidth"
   echo "cacheheight=$bap_imageHeight"
   echo "bloblink=$bap_postedBlob"
   } > "$cachePath/cache.txt"
   cp -f "$bap_preparedImage" "$cachePath/cache.${bap_preparedImage##*.}"
   bloblink=$bap_postedBlob # don't run sed after image upload
}

function convertGifToVideo () {
   if ! type ffmpeg >/dev/null 2>&1; then >&2 echo "Can't convert GIF to MP4 because ffmpeg was not found"; return 1; fi
   ffmpeg -hide_banner -loglevel warning -i "$1" -movflags faststart -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" "$bap_preparedImage" || { iberr "Conversion failed"; rm "$bap_preparedImage"; return 1; }
   return 0
}

function isAniGIF () {
   local var=$(exiftool -b -FrameCount "$1")
   if [ -z "$var" ]; then echo 0; else echo $var; fi
}

function prepareVideo () {
   bap_preparedImage=/tmp/$(uuidgen).mp4
   if [ "$imgtype" = "gif" ]; then convertGifToVideo "$1" || return $?; else cp "$1" "$bap_preparedImage" || return $?; fi
   exiftool -all= "$bap_preparedImage" -overwrite_original || { iberr "Exif scrub failed"; rm "$bap_preparedImage"; return 1; }
   bap_preparedMime=$(file --mime-type -b $bap_preparedImage)
   bap_preparedSize=$(stat -c %s $bap_preparedImage)
   bap_imageWidth=$(exiftool -ImageWidth -s3 $bap_preparedImage)
   bap_imageHeight=$(exiftool -ImageHeight -s3 $bap_preparedImage)
}
