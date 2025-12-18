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
  trap yeet_the_child ERR

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

  while ! ( send_work ); do true; done #&>> ${name}.sender.log

(
  while ! af_do_work; do sleep 1; done

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


  if [ $? -eq 137 ]; then
    echo received immidiate exit
    exit
  fi
  return 0
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

get_msa_too() {
  (
  while read l ; do
    echo $l;  jq < $l | grep Path\": | rev | cut -f2 -d\" | rev | sed "s~^~./$input/~g";
  done 2>/dev/null
  )
}

cleanup() {
  echo exiting
  echo deleting tmp
  kill -9 $(jobs -p)
  kill -9 $(jobs -p)

  rm -rf ${tmpfiles[@]} workdir/
  echo ctrl c to kill now

  for i in ${created_vms[@]}; do
    delete-vm $i
  done
}

yeet_the_child() {
  kill -9 $(jobs -p)
}


fancy() {
  total=$(ls $input | wc -l)

  (
  cur=0
  prev=0
  timeout=1200 # 20 min
  while [ $total -ge $cur ] || [ $timeout -gt 0 ]; do
    timeout=$((timeout - 1))
    cur=$(ls $output | wc -l)
    diff=$((cur - prev))
    seq 0 $diff | sed 1d
    prev=$cur
    sleep 1
  done
  ) |
  pv -l -s $total > /dev/null
}

main_af() {

  trap yeet_the_child EXIT
  trap yeet_the_child ERR

  files=( $(get_files) )
  files_m=$(( ${#files[@]} -1 ))
  step=$(( files_m / max_vms ))
  files_i=0

  while [ $files_m -ge $files_i ] ; do
    t_d=$(mktemp -dp .)
    tmpfiles+=($PWD/$t_d/)

    for i in `seq $files_i $(( step + files_i ))`; do
      echo ${files[$i]}
    done | get_msa_too  | sort | uniq > $t_d/part.txt
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
