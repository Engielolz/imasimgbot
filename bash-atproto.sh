#!/bin/bash

# $1 must be our DID of the account
bapecho="echo bash-atproto:"
did_regex="^did:\S*:\S*"
coverWarn=0

function loadSecrets () {
   if [[ -f $1 ]]; then while IFS= read -r line; do declare -g "$line"; done < "$1"
   return 0
   else return 1
   fi
}

function saveSecrets () {
   $bapecho 'Updating secrets'
   echo 'savedAccess='$savedAccess > $1
   echo 'savedRefresh='$savedRefresh >> $1
   echo 'savedDID='$savedDID >> $1
   echo 'savedAccessTimestamp='$(date +%s) >> $1
   return 0
}

function processAPIError () {
   $bapecho 'Function' $1 'encountered an API error'
   APIErrorCode=$(echo ${!2} | jq -r .error)
   APIErrorMessage=$(echo ${!2} | jq -r .message)
   $bapecho 'Error code:' $APIErrorCode
   $bapecho 'Message:' $APIErrorMessage
   if [ "$APIErrorCode" = "AccountTakedown" ] || [ "$APIErrorCode" = "InvalidRequest" ] || [ "$APIErrorCode" = "InvalidToken" ]; then 
      $bapecho "Safety triggered. Dumping error and shutting down."
      echo ${!2} > ./fatal.json
      exit 115
   fi;
}

function processCurlError () {
   $bapecho "cURL threw an exception $error in function $1"
}

function getKeys () { # 1: failure 2: user error
   if [ -z "$2" ]; then $bapecho "No app password was passed"; return 2; fi
   $bapecho 'fetching keys'
   keyInfo=$(curl --fail-with-body -s -X POST -H 'Content-Type: application/json' -d "{ \"identifier\": \"$1\", \"password\": \"$2\" }" "https://bsky.social/xrpc/com.atproto.server.createSession")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'fatal: failed to authenticate'
      if ! [ "$error" = "22" ]; then processCurlError getKeys; return 1; fi
      processAPIError getKeys keyInfo
      echo $keyInfo > failauth.json
      return 1
   fi
   $bapecho secured the keys!
   # echo $keyInfo > debug.json
   savedAccess=$(echo $keyInfo | jq -r .accessJwt)
   savedRefresh=$(echo $keyInfo | jq -r .refreshJwt)
   savedDID=$(echo $keyInfo | jq -r .did)
   # we don't care about the handle
}

function refreshKeys () {
   $bapecho 'Trying to refresh keys...'
   if [ -z "$savedRefresh" ]; then $bapecho "cannot refresh without a saved refresh token"; return 1; fi
   keyInfo=$(curl --fail-with-body -s -X POST -H "Authorization: Bearer $savedRefresh" -H 'Content-Type: application/json' "https://bsky.social/xrpc/com.atproto.server.refreshSession")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'fatal: failed to refresh keys!'
      if ! [ "$error" = "22" ]; then processCurlError refreshKeys; return 1; fi
      processAPIError refreshKeys keyInfo
      echo $keyInfo > failauth.json
      return 1
   fi
   savedAccess=$(echo $keyInfo | jq -r .accessJwt)
   savedRefresh=$(echo $keyInfo | jq -r .refreshJwt)
   savedDID=$(echo $keyInfo | jq -r .did)
}

function postToBluesky () { #1: exception 2: refresh required
   if [ -z "$1" ]; then $bapecho "fatal: No argument given to post"; return 1; fi
   result=$(curl --fail-with-body -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.post\", \"repo\": \"$did\", \"record\": { \"text\": \"$1\", \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.post\", \"langs\": [ \"en-US\" ] } } " "https://bsky.social/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'warning: the post failed.'
      if ! [ "$error" = "22" ]; then processCurlError postToBluesky; return 1; fi
      APIErrorCode=$(echo $result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then processAPIError postToBluesky result; return 1; fi
      $bapecho 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $result | jq -r .uri)
   cid=$(echo $result | jq -r .cid)
   $bapecho "Posted record at $uri"
   return 0
}

function repostToBluesky () { # arguments 1 is uri, 2 is cid. error codes same as postToBluesky
   if [ -z "$1" ] || [ -z "$2" ]; then $bapecho "fatal: Required argument missing"; return 1; fi
   result=$(curl --fail-with-body -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.repost\", \"repo\": \"$did\", \"record\": { \"subject\": { \"uri\": \"$1\", \"cid\": \"$2\" }, \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.repost\" } } " "https://bsky.social/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'warning: repost failed.'
      if ! [ "$error" = "22" ]; then processCurlError repostToBluesky; return 1; fi
      APIErrorCode=$(echo $result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then processAPIError repostToBluesky result; return 1; fi
      $bapecho 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $result | jq -r .uri)
   cid=$(echo $result | jq -r .cid)
   $bapecho "Repost record at $uri"
   return 0
}

function resizeImageForBluesky () {
   $bapecho "need to resize image"
   convert /tmp/bash-atproto/$workfile -resize 2000x2000 /tmp/bash-atproto/new-$workfile
   mv -f /tmp/bash-atproto/new-$workfile /tmp/bash-atproto/$workfile
}

function compressImageForBluesky () {
   $bapecho "image is too big, trying to compress"
   convert /tmp/bash-atproto/$workfile /tmp/bash-atproto/new-${workfile%.*}.jpg
   if [[ $(stat -c %s /tmp/bash-atproto/new-${workfile%.*}.jpg) -gt 1000000 ]]; then $bapecho "image too big to fit in skeet"; rm /tmp/bash-atproto/$workfile /tmp/bash-atproto/new-${workfile%.*}.jpg; return 1; fi
   rm /tmp/bash-atproto/$workfile
   mv -f /tmp/bash-atproto/new-${workfile%.*}.jpg /tmp/bash-atproto/${workfile%.*}.jpg
   workfile=${workfile%.*}.jpg
}

function prepareImageForBluesky () { # 1: error 2 missing dep
   if [ -z "$1" ]; then $bapecho "fatal: no image specified to prepare"; return 1; fi
   mkdir /tmp/bash-atproto 2>/dev/null
   workfile=$(uuidgen)."${1##*.}"
   cp $1 /tmp/bash-atproto/$workfile
   exiftool -all= /tmp/bash-atproto/$workfile -overwrite_original
   if [[ $(identify -format '%w' /tmp/bash-atproto/$workfile) -gt 2000 ]] || [[ $(identify -format '%h' /tmp/bash-atproto/$workfile) -gt 2000 ]]; then resizeImageForBluesky; fi
   if [[ $(stat -c %s /tmp/bash-atproto/$workfile) -gt 1000000 ]]; then 
      compressImageForBluesky
      if ! [ "$?" = "0" ]; then return 1; fi
   fi
   $bapecho "process successful"
   preparedImage=/tmp/bash-atproto/$workfile
   preparedMime=$(file --mime-type -b $preparedImage)
   preparedSize=$(stat -c %s $preparedImage)
   return 0
}

function postBlobToPDS () {
# okay, params are:
# $1 is the file name and path
# $2 is the mime type
   if [ -z "$1" ] || [ -z "$2" ]; then $bapecho "fatal: Required argument missing"; return 1; fi
   result=$(curl --fail-with-body -X POST -H "Authorization: Bearer $savedAccess" -H "Content-Type: $2" --data-binary @"$1" "https://bsky.social/xrpc/com.atproto.repo.uploadBlob")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'warning: upload failed.'
      if ! [ "$error" = "22" ]; then processCurlError postBlobToPDS; return 1; fi
      APIErrorCode=$(echo $result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then processAPIError postBlobToPDS result; return 1; fi
      $bapecho 'error: token needs to be refreshed'
      return 2
   fi
   postedBlob=$(echo $result | jq -r .blob)
   $bapecho "Blob uploaded ($postedBlob) - reference it soon before its gone"
   return 0
}

function postImageToBluesky () { #1: exception 2: refresh required
# param:
# 1 - blob
# 2 - mimetype
# 3 - size
# 4 - alt text
# 5 - text
   if [ -z "$4" ]; then $bapecho "fatal: more arguments required"; return 1; fi
   # there is a disturbing lack of error checking
   result=$(curl --fail-with-body -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "{ \"collection\": \"app.bsky.feed.post\", \"repo\": \"$did\", \"record\": { \"text\": \"$5\", \"createdAt\": \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\", \"\$type\": \"app.bsky.feed.post\", \"embed\": { \"\$type\": \"app.bsky.embed.images\", \"images\": [ { \"alt\": \"$4\", \"image\": { \"\$type\": \"blob\", \"ref\": { \"\$link\": \"$1\" }, \"mimeType\": \"$2\", \"size\": $filesize } } ] } } } " "https://bsky.social/xrpc/com.atproto.repo.createRecord")
   error=$?
   if [ "$error" != "0" ]; then
      $bapecho 'warning: the post failed.'
      if ! [ "$error" = "22" ]; then processCurlError postImageToBluesky; return 1; fi
      APIErrorCode=$(echo $result | jq -r .error)
      if ! [ "$APIErrorCode" = "ExpiredToken" ]; then processAPIError postImageToBluesky result; return 1; fi
      $bapecho 'the token needs to be refreshed'
      return 2
   fi
   uri=$(echo $result | jq -r .uri)
   cid=$(echo $result | jq -r .cid)
   $bapecho "Posted record at $uri"
   return 0
}

function didInit () {
skipDIDFetch=0

if ! [ -z "$savedDID" ]; then
   skipDIDFetch=1
   did=$savedDID
   $bapecho "Using cached DID: $did"
fi


if [[ "$skipDIDFetch" = "0" ]] && [[ "$1" =~ $did_regex ]] ; then
   skipDIDFetch=1
   did=$1
   $bapecho "Using user-specified DID: $did"
fi
if [ "$skipDIDFetch" = "0" ]; then
   $bapecho 'DID not specified. Fetching from ATproto API'
   did=$(curl -s -G --data-urlencode "handle=$1" "https://bsky.social/xrpc/com.atproto.identity.resolveHandle" | jq -r .did)
   if ! [[ "$did" =~ $did_regex ]]; then
      $bapecho "Error obtaining DID from API"
      return 1
   fi
   $bapecho "Using DID from API: $did"
fi
return 0
}

