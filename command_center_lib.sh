#!/bin/bash
source $(dirname $(realpath $0))/lib.sh

in_array() {
  el=$1
  shift 1
  for i in "$@"; do
    if [[ "$i" == "$el" ]]; then
      return 0
    fi
  done
  return 1
}

create_and_send () {
  name=''
  success=0


  trap yeet_the_child EXIT

  echo searching for already running instance
  for name in $(list_running | grep $name_prefix); do
    in_array $name ${created_vms[@]} && continue
    if sssh true; then
      sssh rm -rf $input $output &>/dev/null
      success=1
      break
    else
      delete_vm
    fi
  done

  if [ "$success" -eq 0 ]; then
    echo did not find a avail instance, creating a new one
    name="$name_prefix-$(uuidgen)"
    create_vm $template echo
    echo created $name
    while ! sssh true; do
      sleep 2
    done
  else
    echo found avail vm $name
    sssh rm final_done &>/dev/null
  fi
  created_vms+=($name)
  sleep 1m

  while ! check_health; do sleep 5; done
  echo $name is up - sending work
  echo $name >> created_vms
  while ! ( send_work ); do true; done #&>> ${name}.sender.log

  (
    af_do_work

    fetcher
    delete_vm
  ) &
}

af_do_work() {

### fetcher thread ###
  (
    sleep 1m
    while ! sssh cat final_done; do
      sleep 1m
      fetcher
    done
    touch $output/final_done
  )  &>> ${name}.fetch.log &

  while ! sssh cat final_done &>/dev/null; do
    if ! sssh 'bash work.sh'; then
      echo __failure__
    fi
  done &>> ${name}.work.log

#  if [ $? -eq 137 ]; then
#    echo received immidiate exit
#    exit
#  fi
#  return 0
}

fetcher() {
  buf="$(sssh cat work_done\; rm work_done)"
  sssh rm work_done
  for l in $buf; do
    mkdir -p workdir/$l
    if srsync /root/$output/$l workdir/; then
#      if  [ -e workdir/*/*/*cif ]; then
        cp -r workdir/$l $output/
        rm -rf workdir/$l
#      else
#        continue
#      fi
      sssh "rm -rf /root/$output/$l"
    else
      sleep 20
      srsync /root/$output/$l workdir/
    fi
  done
}

cleanup() {
  echo ctrl c to kill now
  sleep 5
  trap 'echo no, please wait' EXIT HUP INT QUIT PIPE TERM
  echo exiting
  echo deleting tmp
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)

  rm -rf ${tmpfiles[@]} workdir/

  for i in $(cat created_vms); do
    delete-vm $i
  done
}

yeet_the_child() {
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
}

fancy () {
  total=$(ls $input | wc -l)
  start=$(ls $output | wc -l)

  (
    cur=0
    prev=$start
    timeout=99999999
    while [ $cur -lt $total ] && [ $timeout -gt 0 ]
    do
      cur=$(ls $output | wc -l)
      if [ $prev -eq $cur ]
      then
        timeout=$((timeout - 1))
      else
        timeout=3600
      fi
      diff=$((cur - prev))
      seq 0 $diff | sed 1d
      prev=$cur
      sleep 1
    done
  ) | pv --interval 3 -l -s $((total - start)) > /dev/null
}

main_af() {

  trap yeet_the_child EXIT

  files=( $(get_files) )
  files_m=$(( ${#files[@]} -1 ))
  vms_t=$(( files_m / file_weight ))
  vms_t=$(( vms_t + 1 ))
  if [ $vms_t -lt $max_vms ]; then
    max_vms=$vms_t
  fi
  step=$(( files_m / max_vms ))
  files_i=0

  echo this will create $max_vms
  

  rm created_vms

  while [ $files_m -ge $files_i ] ; do
    t_d=$(mktemp -dp .)
    tmpfiles+=($PWD/$t_d/)

    for i in `seq $files_i $(( step + files_i ))`; do
      echo ${files[$i]}
    done | get_additional_files | sort | uniq > $t_d/part.txt
    files_i=$(( files_i + step + 1 ))

    tar -cf - -T $t_d/part.txt |
    zstd -1 > $t_d/$input.tar.zst
    rm $t_d/part.txt
    work_zstd=$PWD/$t_d/$input.tar.zst
    create_and_send
  done

  while true; do
    refresh_state
    sleep 1m

    for name in ${created_vms[@]}; do
      check_health; health=$?
      zone=$(get_zone_from_name)
      case $health in
        1) power_vm; break;;
        2) reset_vm; break;;
        3) created_vms=( ${created_vms[@]/$name} ); break;;
      esac

    done
  done
}
