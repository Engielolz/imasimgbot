#!/bin/bash

function loadFail () {
   echo "Cannot load required dependency script"
   exit 127
}

function showHelp () {
   echo "usage: ./idolbot.sh <idol> <command>"
   echo "commands:"
   echo "login - specify a did/handle and app-password to generate secrets"
   echo "post - normal behavior to post an image"
   echo "repost - repost another idol bot's post"
}

source ./bash-atproto.sh
if ! [ "$?" = "0" ]; then loadFail; fi

# Check params
if [ -z "$1" ]; then showHelp badParam; exit 1; fi
if [ "$1" = "--help" ]; then showHelp; exit 0; fi


function login () {
   if [ -z "$1" ] || [ -z "$2" ]; then echo "Login params not specified!"; return 1; fi
   getKeys $1 $2
   if ! [ "$?" = "0" ]; then echo "Failed to log in"; return 1
   else saveKeys ./$idol/secrets.env
   return 0
   fi
}









idol=$1
loadSecrets $idol/secrets.env
if ! [ "$?" = "0" ]; then
   if ! [ "$2" = "login" ]; then echo "You need to login first."; fi
   login $1 $2
fi
if [ "$2" = "login" ]; then
   if [ "$3" = "--force" ]; then login $1 $2
   else echo "You are already logged in. Pass --force to log in anyway"; fi
fi
