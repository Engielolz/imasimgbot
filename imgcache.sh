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
