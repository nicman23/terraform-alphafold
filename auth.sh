#!/bin/bash
cd `dirname $0`

[ -e auth.lock ] && exit
touch auth.lock

pkill Xtightvnc
pkill -9 firefox
date >> auth.tries


(tightvncserver &> VNC) &
sleep 5

export DISPLAY=:$(grep compchem-NAS VNC | cut -f2 -d : | head -n1 )

echo found display \'"$DISPLAY"\'
while ! xhost +local: ; do sleep 1; done
openbox &
sleep 2

./google-cloud-sdk/bin/gcloud auth login
./google-cloud-sdk/bin/gcloud auth application-default login
sleep 1
pgrep -fa 'firefox -new-window https://accounts.google.com/' | awk '{print $1}' | xargs kill

rm auth.lock
pkill Xtightvnc
