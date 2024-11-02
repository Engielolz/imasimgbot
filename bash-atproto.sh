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


function saveKeys () {
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
      exit 1
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
   $bapecho "Repost record at $uri"
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

