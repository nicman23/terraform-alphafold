#!/bin/bash

export PATH="$(dirname $(realpath $0))/google-cloud-sdk/bin:$PATH"
#DIRPATH="$(dirname $(realpath $0))"
#tfvar=terraform.tfvars.json
#tfvar_tmp=$DIRPATH/tmp_$tfvar
#tfvar=$DIRPATH/$tfvar
if [ ! -e $DIRPATH ]; then echo something fucky with dirpath; exit 5; fi

clouds=( $(cat $DIRPATH/.avail.clouds) )
cloud_functions=(get_sub_zones get_ip_from_name get_zone_from_name reset_vm check_health list_defined list_running power_vm )
#fucking disgusting
for t_cloud in ${clouds[@]}; do
  source $DIRPATH/lib_${t_cloud}.sh
done

source <(
	for function_cloud in ${cloud_functions[@]}; do
	  echo ${function_cloud}'() {'
    echo 'if [ -z "$cloud" ]; then for cloud in ${clouds[@]}; do'
	  echo \ \ ${function_cloud}_\${cloud} '"$@"'
	  echo 'done; else'
	  echo  ${function_cloud}_\${cloud} '"$@"'
	  echo 'fi'
	  echo '}'
	done
)

sssh() {
  ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=2 -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=15 -l root $(get_ip_from_name) "$@" 2>/dev/null
}

srsync() {
  echo getting file $1 from $name
  timeout 20m rsync -re 'ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=50 -l root' $(get_ip_from_name):"$1" "$2"
}

apply_changes() {
  (
  cd $DIRPATH
  if [ $(wc -l $tfvar_tmp | awk '{print $1}') -eq 0 ]; then echo 0 line json $name >> serious; exit; fi
  if terraform apply -lock-timeout=120s -var-file=$tfvar_tmp <<< yes >> terraform.log; then
    cp $tfvar_tmp $tfvar
    rm $tfvar_tmp
    return 0
  else
    rm $tfvar_tmp
    return 1
  fi
  )
}

refresh_state() {
  (
    cd $DIRPATH
    [ $(( $(date +%s) - $(stat -c %Y "$DIRPATH/terraform.tfstate") )) -lt 5 ] && return 0
    terraform refresh &>/dev/null
  )
}

last_zone=asd-dsa-asd
create_vm () {
  template=$1
  [ -z "$2" ] && ban=$(cat last_zone) || ban=$2
  ban=$( echo $ban | cut -f1,2 -d-)
  wait_for_lock
  [ -z "$name" ] && name=vm-$(uuidgen)

  # dont fail if the requested name is already present in the terraform vars json
  if jq -e --arg nm "$name" '.vms[$nm]' "$tfvar" >/dev/null 2>&1; then
    echo "name '$name' already defined in $tfvar"
    delete-vm
  fi
  machine_type=$(eval echo $(jq .machine_type < $DIRPATH/templates/${template}))
  cloud=$(eval echo $(jq .cloud < $DIRPATH/templates/${template}))
  buf="$(get_sub_zones | grep -v $ban) $(get_sub_zones)"

  while true; do
    for zone in $buf; do
      echo $name will try zone $zone
      jq --slurpfile vm <(jq '.zone = "'$zone'"' $DIRPATH/templates/${template}) '.'vms'["'$name'"] = $vm[0]' $tfvar > $tfvar_tmp
      if apply_changes; then
        echo $zone > last_zone
        while ! check_responding; do sleep 1; done
        return 0
      fi
    done
  done
}

wait_for_lock() {
  if [ -e $tfvar_tmp ]; then
#  while [ -e $tfvar_tmp ] && [ $(( $(date +%s) - $(stat -c %Y "$tfvar_tmp") )) -lt 300 ]; do
    echo lock file $tfvar_tmp exists;
    echo please wait
    while [ -e $tfvar_tmp ]; do
      sleep 1
    done
  fi
  touch  $tfvar_tmp
}

mass_delete_vm() {
  wait_for_lock
  buf="$(cat $tfvar)"

  for name in $@; do
    buf=$(echo "$buf" | jq 'del(.vms["'$name'"])')
  done
  echo "$buf" > $tfvar_tmp
  apply_changes
}

delete_vm () {
  wait_for_lock
  jq 'del(.vms["'$name'"])' $tfvar > $tfvar_tmp
  apply_changes
}

get_zone_from_name() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

# advanced bash regardation
check_responding() {
  refresh_state
  for try in {1..10}; do
    if ping -qc $(( 1 + ((try -1)*10) )) $(get_ip_from_name) &>/dev/null; then
      (
        cat << EOF
        $(type get_ip_from_name_${cloud} | sed 1d)
        $(type get_ip_from_name | sed 1d)
        $(type sssh | sed 1d)

        DIRPATH=$DIRPATH
        name=$name
        cloud=$cloud

        sssh true
EOF
      ) | timeout 10 bash - && {
        return 0
      }
    fi
  done
return 1
}
