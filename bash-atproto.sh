#!/bin/bash
# SPDX-License-Identifier: MIT

# you can change these
bap_plcDirectory=https://plc.directory
bap_handleResolveURL=https://public.api.bsky.app
bap_curlUserAgent="curl/$(curl -V | awk 'NR==1{print $2}') bash-atproto/1"
bap_chmodSecrets=1
bap_verbosity=1

function baperr () {
   >&2 echo "bash-atproto: $*"
}

function bapecho () {
   if [ ! "$bap_verbosity" -ge 1 ]; then return 0; fi
   echo "bash-atproto: $*"
}

function bapverbose () {
   if [ ! "$bap_verbosity" -ge 2 ]; then return 0; fi
   echo "bash-atproto: $*"
}

function bap_loadSecrets () {
   if [[ -f $1 ]]; then while IFS= read -r line; do declare -g "$line"; done < "$1"
   return 0
   else return 1
   fi
}

function bap_saveSecrets () {
   bapecho 'Updating secrets'
   echo 'savedAccess='$savedAccess > $1
   echo 'savedRefresh='$savedRefresh >> $1
   echo 'savedDID='$savedDID >> $1
   echo 'savedAccessTimestamp='$(date +%s) >> $1
   echo 'savedPDS='$savedPDS >> $1
   if [ "$bap_chmodSecrets" != "0" ]; then chmod 600 $1; fi
   return 0
}

function bapInternal_processAPIError () {
   baperr 'Function' $1 'encountered an API error'
   APIErrorCode=$(echo ${!2} | jq -r .error)
   APIErrorMessage=$(echo ${!2} | jq -r .message)
   baperr 'Error code:' $APIErrorCode
   baperr 'Message:' $APIErrorMessage
   if [ "$APIErrorCode" = "AccountTakedown" ] || [ "$APIErrorCode" = "InvalidRequest" ] || [ "$APIErrorCode" = "InvalidToken" ]; then 
      baperr "Safety triggered. Dumping error and shutting down."
      echo ${!2} > ./fatal.json
      exit 115
   fi;
}

function bapInternal_processCurlError () {
   baperr "cURL threw an exception $error in function $1"
}

function bap_getKeys () { # 1: failure 2: user error
   if [ -z "$2" ]; then baperr "No app password was passed"; return 2; fi
   bapecho 'fetching keys'
   bap_keyInfo=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H 'Content-Type: application/json' -d "{ \"identifier\": \"$1\", \"password\": \"$2\" }" "$savedPDS/xrpc/com.atproto.server.createSession")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'fatal: failed to authenticate'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_getKeys; return 1; fi
      bapInternal_processAPIError bap_getKeys bap_keyInfo
      echo $bap_keyInfo > failauth.json
      return 1
   fi
   bapecho secured the keys!
   # echo $bap_keyInfo > debug.json
   savedAccess=$(echo $bap_keyInfo | jq -r .accessJwt)
   savedRefresh=$(echo $bap_keyInfo | jq -r .refreshJwt)
   savedDID=$(echo $bap_keyInfo | jq -r .did)
   # we don't care about the handle
}

function bap_refreshKeys () {
   bapecho 'Trying to refresh keys...'
   if [ -z "$savedRefresh" ]; then baperr "cannot refresh without a saved refresh token"; return 1; fi
   bap_keyInfo=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedRefresh" -H 'Content-Type: application/json' "$savedPDS/xrpc/com.atproto.server.refreshSession")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'fatal: failed to refresh keys!'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_refreshKeys; return 1; fi
      bapInternal_processAPIError bap_refreshKeys bap_keyInfo
      echo $bap_keyInfo > failauth.json
      return 1
   fi
   savedAccess=$(echo $bap_keyInfo | jq -r .accessJwt)
   savedRefresh=$(echo $bap_keyInfo | jq -r .refreshJwt)
   savedDID=$(echo $bap_keyInfo | jq -r .did)
}

function bap_postToBluesky () { #1: exception 2: refresh required
   if [ -z "$1" ]; then baperr "fatal: No argument given to post"; return 1; fi
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.post\", \"repo\": \"$savedDID\", \"record\": { \"text\": \"$1\", \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.post\", \"langs\": [ \"en-US\" ] } } " "$savedPDS/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'warning: the post failed.'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_postToBluesky; return 1; fi
      APIErrorCode=$(echo $bap_result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError bap_postToBluesky bap_result; return 1; fi
      baperr 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Posted record at $uri"
   return 0
}

function bap_repostToBluesky () { # arguments 1 is uri, 2 is cid. error codes same as postToBluesky
   if [ -z "$2" ]; then baperr "fatal: Required argument missing"; return 1; fi
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.repost\", \"repo\": \"$savedDID\", \"record\": { \"subject\": { \"uri\": \"$1\", \"cid\": \"$2\" }, \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.repost\" } } " "$savedPDS/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'warning: repost failed.'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_repostToBluesky; return 1; fi
      APIErrorCode=$(echo $bap_result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError bap_repostToBluesky bap_result; return 1; fi
      baperr 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Repost record at $uri"
   return 0
}

function bapHelper_resizeImageForBluesky () {
   bapecho "need to resize image"
   convert /tmp/bash-atproto/$workfile -resize 2000x2000 /tmp/bash-atproto/new-$workfile
   if ! [ "$?" = "0" ]; then baperr "fatal: convert failed!"; rm /tmp/bash-atproto/$workfile 2>/dev/null; return 1; fi
   mv -f /tmp/bash-atproto/new-$workfile /tmp/bash-atproto/$workfile
}

function bapHelper_compressImageForBluesky () {
   bapecho "image is too big, trying to compress"
   convert /tmp/bash-atproto/$workfile -define jpeg:extent=1000kb /tmp/bash-atproto/new-${workfile%.*}.jpg
   if [[ ! "$?" = "0" ]] || [[ $(stat -c %s /tmp/bash-atproto/new-${workfile%.*}.jpg) -gt 1000000 ]]; then baperr "fatal: error compressing image or image too big to fit in skeet"; rm /tmp/bash-atproto/$workfile /tmp/bash-atproto/new-${workfile%.*}.jpg; return 1; fi
   rm /tmp/bash-atproto/$workfile
   mv -f /tmp/bash-atproto/new-${workfile%.*}.jpg /tmp/bash-atproto/${workfile%.*}.jpg
   workfile=${workfile%.*}.jpg
}

function bap_prepareImageForBluesky () { # 1: error 2 missing dep
   if [ -z "$1" ]; then baperr "fatal: no image specified to prepare"; return 1; fi
   mkdir /tmp/bash-atproto 2>/dev/null
   workfile=$(uuidgen)."${1##*.}"
   cp $1 /tmp/bash-atproto/$workfile
   exiftool -all= /tmp/bash-atproto/$workfile -overwrite_original
   if ! [ "$?" = "0" ]; then baperr "fatal: exiftool failed!"; rm /tmp/bash-atproto/$workfile 2>/dev/null; return 1; fi
   if [[ $(identify -format '%w' /tmp/bash-atproto/$workfile) -gt 2000 ]] || [[ $(identify -format '%h' /tmp/bash-atproto/$workfile) -gt 2000 ]]; then
      bapHelper_resizeImageForBluesky
      if ! [ "$?" = "0" ]; then return 1; fi
   fi
   if [[ $(stat -c %s /tmp/bash-atproto/$workfile) -gt 1000000 ]]; then 
      bapHelper_compressImageForBluesky
      if ! [ "$?" = "0" ]; then return 1; fi
   fi
   bapecho "image preparation successful"
   bap_preparedImage=/tmp/bash-atproto/$workfile
   bap_preparedMime=$(file --mime-type -b $bap_preparedImage)
   bap_preparedSize=$(stat -c %s $bap_preparedImage)
   bap_imageWidth=$(identify -format '%w' $bap_preparedImage)
   bap_imageHeight=$(identify -format '%h' $bap_preparedImage)
   return 0
}

function bap_postBlobToPDS () {
# okay, params are:
# $1 is the file name and path
# $2 is the mime type
   if [ -z "$2" ]; then baperr "fatal: Required argument missing"; return 1; fi
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H "Content-Type: $2" --data-binary @"$1" "$savedPDS/xrpc/com.atproto.repo.uploadBlob")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'warning: upload failed.'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_postBlobToPDS; return 1; fi
      APIErrorCode=$(echo $bap_result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError bap_postBlobToPDS bap_result; return 1; fi
      baperr 'error: token needs to be refreshed'
      return 2
   fi
   bap_postedBlob=$(echo $bap_result | jq -r .blob.ref.'"$link"')
   bap_postedMime=$(echo $bap_result | jq -r .blob.mimeType)
   bap_postedSize=$(echo $bap_result | jq -r .blob.size)
   bapecho "Blob uploaded ($bap_postedBlob)"
   return 0
}

function bap_postImageToBluesky () { #1: exception 2: refresh required
# param:
# 1 - blob
# 2 - mimetype
# 3 - size
# 4 - width
# 5 - height
# 6 - alt text
# 7 - text
   if [ -z "$5" ]; then baperr "fatal: more arguments required"; return 1; fi
   # there is a disturbing lack of error checking
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.post\", \"repo\": \"$savedDID\", \"record\": { \"text\": \"$7\", \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.post\", \"embed\": { \"\$type\": \"app.bsky.embed.images\", \"images\": [ { \"alt\": \"$6\", \"aspectRatio\": { \"height\": $5, \"width\": $4 }, \"image\": { \"\$type\": \"blob\", \"ref\": { \"\$link\": \"$1\" }, \"mimeType\": \"$2\", \"size\": $3 } } ] } } } " "$savedPDS/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'warning: the post failed.'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_postImageToBluesky; return 1; fi
      APIErrorCode=$(echo $bap_result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError bap_postImageToBluesky bap_result; return 1; fi
      baperr 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Posted record at $uri"
   return 0
}

function bap_prepareVideoForBluesky () {
   # stub, will actually talk to bluesky video service in the future
   # $1 is file
   # $2 is mime (like bap_postBlobToPDS)
   if [ -z "$2" ]; then baperr "fatal: Required argument missing"; return 1; fi
   if [[ $(stat -c %s $1) -gt 50000000 ]]; then baperr 'fatal: video may not exceed 50 mb'; return 1; fi
   bap_postBlobToPDS $1 $2
   if [ "$?" != "0" ]; then baperr "warning: video upload failed"; return 1; fi
   bap_imageWidth=$(exiftool -ImageWidth -s3 $1)
   bap_imageHeight=$(exiftool -ImageHeight -s3 $1)
   bapecho 'video "posted"'
   return 0
}

function bap_postVideoToBluesky () {
# param:
# 1 - blob
# 2 - size
# 3 - width
# 4 - height
# 5 - alt text
# 6 - text
# assuming video/mp4 is always the mimetype might be a bad assumption
   if [ -z "$4" ]; then baperr "fatal: more arguments required"; return 1; fi
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.post\", \"repo\": \"$savedDID\", \"record\": { \"text\": \"$6\", \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.post\", \"embed\": { \"alt\": \"$5\", \"\$type\": \"app.bsky.embed.video\", \"video\": { \"\$type\": \"blob\", \"ref\": { \"\$link\": \"$1\" }, \"mimeType\": \"video/mp4\", \"size\": $2 }, \"aspectRatio\": { \"width\": $3, \"height\": $4 } } } } " "$savedPDS/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      baperr 'warning: the post failed.'
      if ! [ "$error" = "22" ]; then bapInternal_processCurlError bap_postVideoToBluesky; return 1; fi
      APIErrorCode=$(echo $bap_result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError bap_postVideoToBluesky bap_result; return 1; fi
      baperr 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Posted record at $uri"
   return 0
}

function bap_findPDS () {
   if [ -z "$1" ]; then baperr "fatal: no did specified"; return 1; fi
   bap_didType=0
   if ! [ -z "$(echo $1 | grep did:plc:)" ]; then bap_didType=plc; fi
   if ! [ -z "$(echo $1 | grep did:web:)" ]; then bap_didType=web; fi
   case "$bap_didType" in

      "plc")
      bap_resolve=$(curl -s --fail-with-body -A "$bap_curlUserAgent" "$bap_plcDirectory/$1")
      if ! [ "$?" = "0" ]; then baperr "fatal: did:plc lookup failed"; bapInternal_processCurlError bap_findPDS; return 1; fi
      ;;

      "web")
      bap_resolve=$(curl -s --fail-with-body -A "$bap_curlUserAgent" "$(echo https://$1 | sed 's/did:web://g')/.well-known/did.json")
      if ! [ "$?" = "0" ]; then baperr "fatal: did:web lookup failed"; bapInternal_processCurlError bap_findPDS; return 1; fi
      ;;

      *)
      baperr "fatal: unrecognized did type"
      return 1
      ;;
   esac
   bap_resolve=$(echo $bap_resolve | jq -re .service)
   if ! [ "$?" = "0" ]; then baperr "fatal: failed to parse DID document"; return 1; fi
   iter=0
   while read -r id; do
      if ! [ "$id" = "#atproto_pds" ]; then
         ((iter+=1))
         continue
      fi
      savedPDS=$(echo "$bap_resolve" | jq -r ".[$iter].serviceEndpoint")
      break
   done <<< "$(echo "$bap_resolve" | jq -r .[].id)"
   if [ -z "$savedPDS" ]; then baperr "fatal: PDS not found in DID document"; return 1; fi
   return 0
}

function bap_didInit () {
if [ -z "$1" ]; then baperr "specify identifier as first parameter"; return 1; fi

if [[ "$1" =~ ^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]$ ]] ; then
   savedDID=$1
   bapecho "Using user-specified DID: $savedDID"
   return 0

elif [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
   bapecho "Looking up handle from $bap_handleResolveURL"
   savedDID=$(curl -s -A "$bap_curlUserAgent" -G --data-urlencode "handle=$1" "$bap_handleResolveURL/xrpc/com.atproto.identity.resolveHandle" | jq -re .did)
   if [ "$?" != "0" ]; then
      baperr "Error obtaining DID from API"
      return 1
   fi
   bapecho "Using DID from API: $savedDID"

else
   baperr "input not a handle or did"
   return 1

fi
return 0
}
