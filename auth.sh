#!/bin/bash
cd `dirname $0`

[ -e auth.lock ] && exit
touch auth.lock

pkill -9 firefox

date >> auth.tries

pgrep -u `whoami` -fa Xvnc || Xvnc
sleep 2
export DISPLAY=$(pgrep -u `whoami` -fa Xvnc 2>&1 | sed -E 's/.*(:[0-9][0-9]*).*/\1/g')

./google-cloud-sdk/bin/gcloud auth login
./google-cloud-sdk/bin/gcloud auth application-default login
sleep 1
pgrep -fa 'firefox -new-window https://accounts.google.com/' | awk '{print $1}' | xargs kill

rm auth.lock
