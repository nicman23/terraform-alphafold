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
  name="$name_prefix-$(uuidgen)"
    create_vm $template echo
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
  #do not redo work
  while ! ( send_work ); do true; done #&>> ${name}.sender.log

(
  while ! af_do_work; do sleep 1; done

  delete_vm
) &
}

send_work() {
#  set -xe
  sssh rm -rf $output $input workdir work_done final_done &>/dev/null
  pv $work_zstd | sssh 'zstd -d | tar -xf -'
  ls af_output/ |
   sssh 'while read dir; mkdir -p $dir'
  cat << EOF | sssh cat - \> work.sh
  ln -fs /root/mlibs /root/public_databases
  rm -rf $output workdir
  mkdir $output workdir
  cd $input
  rm /root/work_done /root/final_done
  for i in *json; do
    mkdir -p /root/workdir/\$i
    cp /root/$input/\$i /root/workdir/\$i/
    [ -e /root/$output/\$i ] && continue
    mkdir -p /root/workdir/\$i/msa_outputs
    docker kill main
    docker rm main
    docker run --name main -d  \
      --volume /root/:/root/ \
      --gpus=all \
      alphafold3 \
      python run_alphafold.py \
      --run_inference=True \
      --run_data_pipeline=False \
      --json_path=/root/$input/\$i \
      --model_dir=/root/models \
      --output_dir=/root/workdir/\$i
    docker wait main
    docker logs main > /root/workdir/\$i/log
    docker rm main
    mv /root/workdir/\$i /root/$output/
    echo \$i >> /root/work_done

  done
  touch /root/final_done
EOF
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

  while ! sssh cat final_done; do
    if ! sssh 'bash work.sh' &>> ${name}.work.log ; then
      
      echo __failure__ &>> ${name}.work.log
    fi
  done

  fetcher
  touch $output/final_done
  return 0
}

fetcher() {
  buf="$(sssh cat work_done; rm work_done)"
  for l in $buf; do
    mkdir -p workdir/$l
    srsync /root/$output/$l workdir/
    rm -rf $output/$l
    mv workdir/$l $output/
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
  rm -rf ${tmpfiles[@]} workdir/
  echo ctrl c to kill now
sleep 1m
  kill -9 $(jobs -p)
  sleep 1
  kill -9 $(jobs -p)
  sleep 1
  kill -9 $(jobs -p)
  kill -9 $(jobs -p)

  for i in ${created_vms[@]}; do
    delete-vm $i
  done
}

fancy() {
  total=$(ls $input | wc -l)

  (
  cur=0
  prev=0

  while [ $total -gt $cur ]; do
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
      check_health; health=$$

      if [ $health -eq 1 ]; then
        power_vm
        sleep 30
      elif [ $health -eq 2 ]; then
        reset_vm
        sleep 30
      fi

    done
  done
}