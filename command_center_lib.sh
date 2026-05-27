#!/bin/bash
#source $(dirname $(realpath $0))/lib.sh


SCRIPT_DIR="$(dirname $(realpath $0))"
WORK_DIR="$(pwd)"
SESSION_DIR="$WORK_DIR/terraform-alphafold-session"
SESSION_MODE="${SESSION_MODE:-0}"

setup_session_dir() {
  export DIRPATH="$(dirname $(realpath $0))"
  [ "$SESSION_MODE" == "1" ] && {   export DIRPATH="$SESSION_DIR";  }
  export tfvar=terraform.tfvars.json
  export tfvar_tmp=$DIRPATH/tmp_$tfvar
  export tfvar=$DIRPATH/$tfvar
  [ "$SESSION_MODE" != "1" ] && { source "$SCRIPT_DIR/lib.sh"; return; }

  if [ -d "$SESSION_DIR" ]; then
    echo "Using existing session directory: $SESSION_DIR"
  else
    echo "Creating session directory: $SESSION_DIR"
    (
      cp -r "$SCRIPT_DIR" "$SESSION_DIR"
      cd "$SESSION_DIR"
      jq '.vms = {}' "$tfvar" > "$tfvar_tmp"
      mv "$tfvar_tmp" "$tfvar"
      terraform init
    )
  fi
  source "$SESSION_DIR/lib.sh"
}

cleanup_session_dir() {
  [ "$SESSION_MODE" != "1" ] && return
  echo "Cleaning up session directory: $SESSION_DIR"
  cd "$SESSION_DIR"
  echo "Destroying managed VMs..."
  wait_for_lock
  jq '.vms = {}' "$tfvar" > "$tfvar_tmp"
  apply_changes
  echo "Removing session directory..."
  cd "$WORK_DIR"
#  rm -rf "$SESSION_DIR"
}

setup_session_dir

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

  echo searching for already running instance with the prefix $name_prefix
  for name in $(list_running | grep $name_prefix); do
    in_array $name $( cat created_vms ) && continue
    echo checking $name
    if sssh true; then
      sssh rm -rf $input $output &>/dev/null
      success=1
      break
    else
      echo check $name
      echo delete called on $name
      delete_vm
    fi
  done

  if [ "$success" -eq 0 ]; then

    refresh_state
    need_check=1
    while [ $need_check -eq 1 ]; do
      need_check=0
      for name in $(list_running); do
        if [ -z $(get_ip_from_name) ]; then
          need_check=1
          power_vm || recreate_vm
        fi
      done
    done

    name=''
    echo did not find a avail instance, naming a new one
    name="$name_prefix-$(uuidgen)"
    create_vm $template
  else
    echo found avail vm $name
    sssh rm final_done &>/dev/null
  fi
  echo $name >> created_vms

  (
    send_work
    af_do_work

    fetcher
    delete_vm
  ) &
}

recreate_vm() {
  (
    set -x

    echo recreate called on $name >> serious
    echo waiting

    delete_vm

    cat $t_d/part.txt |
      while read part_l; do
        [ -e $output/$(basename $part_l) ] && continue
        echo $part_l
      done > $t_d/part2.txt

    tar -cf - -T $t_d/part2.txt |
    zstd -1 > $work_zstd

    create_vm $template $zone

    echo sending
    send_work
    set +x
  ) >> ${name}.recreate.log
}

doctor() {
  [ ! -e creation_done ] && return 0
  (
#    refresh_state
echo td is $t_d
set -x
    check_health; health=$?

    case check_health in
      0) return 0;;
      1) power_vm || recreate_vm;;
      2) reset_vm || recreate_vm;;
      3) recreate_vm;;
    esac

    send_work
set +x
  ) &> ${name}.doctor.log
}

#0 on done
check_done() {
  [[ 'done' == $(sssh sh -c '[ $( ( ls '$input' || echo asd ) | wc -l) -gt $( (ls '$output' || echo -n ) | wc -l ) ] && echo done' ) ]]
}

af_do_work() {
  (
    set -x
    sleep 1m
    while ! check_done; do
      sleep 1m
      fetcher
    done
    touch $output/final_done
    set +x
  )  &>> ${name}.fetch.log &

  try_before_doctor=0
  (
    set -x
    while ! check_done; do #&>/dev/null; do
      if ! sssh 'bash work.sh'; then
        echo ____vm seams down____  $name >> serious
        if [ $try_before_doctor -ge 5 ]; then
          doctor
        else
          sleep 30
          try_before_doctor=$(( try_before_doctor +1 ))
        fi
      fi
    done
    echo 'work_done!!'
    set +x
  )   &>> ${name}.work.log
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
#
#  for i in $(cat created_vms); do
#    delete-vm $i
#  done

#  cleanup_session_dir
}

yeet_the_child() {
  trap 'echo no, please wait' EXIT HUP INT QUIT PIPE TERM
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
  kill -15 $(jobs -p)
}

fancy () {
  [ -z "$fancy_ignore" ] && fancy_ignore=asdasdasdasdasdasdasd
  total=$(ls $input | grep -v "$fancy_ignore" | wc -l)
  start=$(ls $output | grep -v 'final_done' | wc -l)
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
  echo -n > created_vms
  rm creation_done

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

  while [ $files_m -ge $files_i ] ; do
    t_d=$(mktemp -dp .)
    tmpfiles+=($PWD/$t_d/)

    for i in `seq $files_i $(( step + files_i ))`; do
      echo ${files[$i]}
    done | get_additional_files | sort | uniq > $t_d/part.txt
    files_i=$(( files_i + step + 1 ))

    work_zstd=$PWD/$t_d/$input.tar.zst

    tar -cf - -T $t_d/part.txt |
    zstd -1 > $t_d/$input.tar.zst

    create_and_send
  done
  echo > creation_done
}
