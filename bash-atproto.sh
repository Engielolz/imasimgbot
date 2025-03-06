#!/bin/bash
# SPDX-License-Identifier: MIT

# you can change these
bap_plcDirectory=https://plc.directory
bap_handleResolveURL=https://public.api.bsky.app
bap_curlUserAgent="curl/$(curl -V | awk 'NR==1{print $2}') bash-atproto/2"
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

function bap_decodeJwt () {
   bap_jwt="$(echo $1 | cut -d '.' -f 2 \
   | sed  's/$/====/' | fold -w 4 | sed '$ d' | tr -d '\n' | tr '_-' '/+' \
   | base64 -d | jq -re)" || { baperr "not a jwt"; return 1; }
   # 1: fetch JWT payload 2: pad and convert to base64 3: decode
   return 0
}

function bapInternal_loadFromJwt () {
   savedDID="$(echo $bap_jwt | jq -r .sub)"
   savedPDS="https://$(echo $bap_jwt | jq -r .aud | sed 's/did:web://g')"
   savedAccessTimestamp="$(echo $bap_jwt | jq -r .iat)" #deprecated
   savedAccessExpiry="$(echo $bap_jwt | jq -r .exp)"
}

function bap_loadSecrets () {
   if [[ -f $1 ]]; then while IFS= read -r line; do declare -g "$line"; done < "$1"
   bap_decodeJwt "$savedAccess" || return 1
   bapInternal_loadFromJwt
   return 0
   else return 1
   fi
}

function bap_saveSecrets () {
   bapecho 'Updating secrets'
   echo 'savedAccess='$savedAccess > "$1"
   echo 'savedRefresh='$savedRefresh >> "$1"
   if [ "$bap_chmodSecrets" != "0" ]; then chmod 600 "$1"; fi
   return 0
}

function bapInternal_processAPIError () {
   baperr 'Function' $1 'encountered an API error'
   APIErrorCode=$(echo ${!2} | jq -r .error)
   APIErrorMessage=$(echo ${!2} | jq -r .message)
   baperr 'Error code:' $APIErrorCode
   baperr 'Message:' $APIErrorMessage
}

function bapInternal_errorCheck () {
   case $1 in
      0);;
      22)
         if [ ! -z "$3" ]; then baperr "$3"; fi
         APIErrorCode=$(echo $bap_result | jq -r .error)
         if ! [ "$APIErrorCode" = "ExpiredToken" ]; then bapInternal_processAPIError $2 bap_result; return 1; fi
         baperr 'the token needs to be refreshed'
         return 2;;
      *)
         if [ ! -z "$3" ]; then baperr "$3"; fi
         baperr "cURL threw exception $1 in function $2"
         return 1;;
   esac
}

function bapInternal_verifyStatus () {
   if [ "$(echo $bap_result | jq -r .active)" = "false" ]; then
      baperr "warning: account is inactive"
      if [ ! -z "$(echo $bap_result | jq -r .status)" ]; then baperr "pds said: $(echo $bap_result | jq -r .status)"; else baperr "no reason was given for the account not being active"; fi
      return 115
   fi
}

function bapInternal_validateDID () {
   if ! [[ "$1" =~ ^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]$ ]]; then baperr "fatal: input not a did"; return 1; fi
   return 0
}

function bap_getKeys () { # 1: failure 2: user error
   if [ -z "$2" ]; then baperr "No app password was passed"; return 2; fi
   bapecho 'fetching keys'
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H 'Content-Type: application/json' -d "{ \"identifier\": \"$1\", \"password\": \"$2\" }" "$savedPDS/xrpc/com.atproto.server.createSession")
   bapInternal_errorCheck $? bap_getKeys "fatal: failed to authenticate" || return $?
   bapecho secured the keys!
   savedAccess=$(echo $bap_result | jq -r .accessJwt)
   savedRefresh=$(echo $bap_result | jq -r .refreshJwt)
   # we don't care about the handle
   bap_decodeJwt $savedAccess
   if [ "$(echo $bap_jwt | jq -r .scope)" != "com.atproto.appPass" ]; then baperr "warning: this is not an app password"; fi
   bapInternal_verifyStatus || return $?
   return 0
}

function bap_refreshKeys () {
   if [ -z "$savedRefresh" ]; then baperr "cannot refresh without a saved refresh token"; return 1; fi
   bapecho 'Trying to refresh keys...'
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedRefresh" "$savedPDS/xrpc/com.atproto.server.refreshSession")
   bapInternal_errorCheck $? bap_refreshKeys "fatal: failed to refresh keys!" || return $?
   savedAccess=$(echo $bap_result | jq -r .accessJwt)
   savedRefresh=$(echo $bap_result | jq -r .refreshJwt)
   bap_decodeJwt $savedAccess
   bapInternal_verifyStatus || return $?
   return 0
}

function bap_closeSession () {
   if [ -z "$savedAccess" ]; then baperr "need access token to close session"; return 1; fi
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedRefresh" "$savedPDS/xrpc/com.atproto.server.deleteSession")
   bapInternal_errorCheck $? bap_closeSession "error: failed to delete session" || return $?
   savedAccess= savedRefresh=
   bapecho "session closed successfully"
   return 0
}

function bapCYOR_str () {
   # for quotes
   if [ -z "$1" ]; then baperr "nothing to add"; return 1; fi
   if [ -z "$bap_cyorRecord" ]; then bap_cyorRecord="{}"; fi
   bap_temp=$2
   bap_cyorRecord=$(echo "$bap_cyorRecord" | jq -c "$3.[\"$1\"]=\"$bap_temp\"")
   return $?
}

function bapCYOR_add () {
   # for things that shouldn't be in quotes
   if [ -z "$1" ]; then baperr "nothing to add"; return 1; fi
   if [ -z "$bap_cyorRecord" ]; then bap_cyorRecord="{}"; fi
   bap_temp=$2
   bap_cyorRecord=$(echo "$bap_cyorRecord" | jq -c "$3.[\"$1\"]=$bap_temp")
   return $?
}

function bapCYOR_rem () {
   # doesn't handle special names atm
   if [ -z "$1" ] || [ -z "bap_cyorRecord" ]; then baperr "nothing to remove"; return 1; fi
   bap_cyorRecord=$(echo $bap_cyorRecord | jq -c "del(.$1)")
   return $?
}

function bapCYOR_bskypost () {
   bap_cyorRecord="{}"
   bapCYOR_str \$type app.bsky.feed.post
   bapCYOR_str text ""
}

function bapInternal_finalizeRecord () {
   if ! jq -e . >/dev/null <<<"$1"; then baperr "can't finalize: JSON parse error"; return 1; fi
   bap_finalRecord="{\"collection\": $(echo $1 | jq -c '.["$type"]'), \"repo\": \"$savedDID\", \"record\": $1}"
   if ! jq -e . >/dev/null <<<"$1"; then baperr "finalize: JSON parse error"; return 1; fi
   return 0
}

function bap_postRecord () {
   bapInternal_finalizeRecord "$1" || { baperr "not posting because finalize failed"; return 1; }
   bap_result=$(curl --fail-with-body -s -A "$bap_curlUserAgent" -X POST -H "Authorization: Bearer $savedAccess" -H 'Content-Type: application/json' -d "$bap_finalRecord" "$savedPDS/xrpc/com.atproto.repo.createRecord")
   bapInternal_errorCheck $? bap_postRecord "failed to post record" || return $?
   return 0
}

function bap_postToBluesky () { #1: exception 2: refresh required
   if [ -z "$1" ]; then baperr "fatal: No argument given to post"; return 1; fi
   bapCYOR_bskypost
   bapCYOR_str text "$1"
   if ! [ -z "2" ]; then bapCYOR_add langs "[\"$2\"]"; fi
   bapCYOR_str createdAt $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
   bap_postRecord "$bap_cyorRecord" || return $?
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Posted record at $uri"
   return 0
}

function bap_repostToBluesky () { # arguments 1 is uri, 2 is cid. error codes same as postToBluesky
   if [ -z "$2" ]; then baperr "fatal: Required argument missing"; return 1; fi
   bap_cyorRecord=
   bapCYOR_str \$type app.bsky.feed.repost
   bapCYOR_str cid $2 .subject
   bapCYOR_str uri $1 .subject
   bapCYOR_str createdAt $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
   bap_postRecord "$bap_cyorRecord" || return $?
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
   bapInternal_errorCheck $? bap_postBlobToPDS "error: blob upload failed" || return $?
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
   # it's easy but just LOOK at all those commands
   bapCYOR_bskypost
   bapCYOR_str text "$7"
   bapCYOR_str \$type app.bsky.embed.images .embed
   bapCYOR_str alt "$6" .embed.images.[0]
   bapCYOR_str \$type blob .embed.images.[0].image
   bapCYOR_str \$link $1 .embed.images.[0].image.ref
   bapCYOR_str mimeType "$2" .embed.images.[0].image
   bapCYOR_add size $3 .embed.images.[0].image
   bapCYOR_add width $4 .embed.images.[0].aspectRatio
   bapCYOR_add height $5 .embed.images.[0].aspectRatio
   bapCYOR_str createdAt $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
   bap_postRecord "$bap_cyorRecord" || return $?
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
   bapCYOR_bskypost
   bapCYOR_str text "$6"
   bapCYOR_str alt "$5" .embed
   bapCYOR_str \$type app.bsky.embed.video .embed
   bapCYOR_str \$type blob .embed.video
   bapCYOR_str \$link "$1" .embed.video.ref
   bapCYOR_str mimeType "video/mp4" .embed.video
   bapCYOR_add size $2 .embed.video
   bapCYOR_add width $3 .embed.aspectRatio
   bapCYOR_add height $4 .embed.aspectRatio
   bapCYOR_str createdAt $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
   bap_postRecord "$bap_cyorRecord"
   bapInternal_errorCheck $? bap_postVideoToBluesky "error: post failed" || return $?
   uri=$(echo $bap_result | jq -r .uri)
   cid=$(echo $bap_result | jq -r .cid)
   bapecho "Posted record at $uri"
   return 0
}

function bap_findPDS () {
   if [ -z "$1" ]; then baperr "fatal: no did specified"; return 1; fi
   bapInternal_validateDID "$1" || return 1
   case "$(echo $1 | cut -d ':' -f 2)" in

      "plc")
      bap_result=$(curl -s --fail-with-body -A "$bap_curlUserAgent" "$bap_plcDirectory/$1")
      bapInternal_errorCheck $? bap_findPDS "fatal: did:plc lookup failed" || return $?
      ;;

      "web")
      bap_result=$(curl -s --fail-with-body -A "$bap_curlUserAgent" "$(echo https://$1 | sed 's/did:web://g')/.well-known/did.json")
      bapInternal_errorCheck $? bap_findPDS "fatal: did:web lookup failed" || return $?
      ;;

      *)
      baperr "fatal: unrecognized did type"
      return 1
      ;;
   esac
   bap_resolve=$(echo $bap_result | jq -re .service)
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

if bapInternal_validateDID $1 2> /dev/null; then
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
   baperr "fatal: input not a handle or did"
   return 1

fi
return 0
}
