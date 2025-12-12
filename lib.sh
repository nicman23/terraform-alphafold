#!/bin/bash

export PATH="$(dirname $(realpath $0))/google-cloud-sdk/bin:$PATH"
DIRPATH="$(dirname $(realpath $0))"
tfvar=terraform.tfvars.json
tfvar_tmp=$DIRPATH/tmp_$tfvar
tfvar=$DIRPATH/$tfvar

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
  ssh -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=15 -l root $(get_ip_from_name) "$@" 2>/dev/null
}

srsync() {
  echo getting file $1 from $name
  rsync -r -e 'ssh -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5 -l root' $(get_ip_from_name):"$1" "$2"
}

apply_changes() {
  (
  cd $DIRPATH

  if terraform apply -var-file=$tfvar_tmp <<< yes >> terraform.log; then
    cp $tfvar_tmp $tfvar
    rm $tfvar_tmp
    return 0
  fi
  return 1
  )
}

refresh_state() {
  (
  cd $DIRPATH
  terraform refresh &>/dev/null
  )
}

create_vm () {
  wait_for_lock
  touch $tfvar_tmp
  [ -z "$name" ] && name=vm-$(uuidgen)

  # fail if the requested name is already present in the terraform vars json
  if jq -e --arg nm "$name" '.vms[$nm]' "$tfvar" >/dev/null 2>&1; then
    echo "name '$name' already defined in $tfvar"
    rm -f "$tfvar_tmp"
    return 1
  fi

  template=$1
  if [ ! -e "$DIRPATH/templates/${template}" ]; then
    echo please select from :
    ls $DIRPATH/templates/ | sed "s~$DIRPATH/templates/~~g"
    echo as a first arguement
  fi
  shift

  machine_type=$(eval echo $(jq .machine_type < $DIRPATH/templates/${template}))
  cloud=$(eval echo $(jq .cloud < $DIRPATH/templates/${template}))
  success_file=$(mktemp -u)

  buf="$(get_sub_zones)"

  while [ ! -e $success_file ]; do
    echo "$buf" |
    while read zone; do
    sleep 1
      jq --slurpfile vm <(jq '.zone = "'$zone'"' $DIRPATH/templates/${template}) '.'vms'["'$name'"] = $vm[0]' $tfvar > $tfvar_tmp
      # exit 1
      if apply_changes; then
        echo yep >> $success_file
        return 0
      fi
    done
  done
  [ -e $success_file ]
}

wait_for_lock() {
  while [ -e $tfvar_tmp ]; do
    echo lock file $tfvar_tmp exists;
    echo please wait
    sleep 1
  done
}

delete_vm () {
  wait_for_lock

  touch $tfvar_tmp
  jq 'del(.vms["'$name'"])' $tfvar > $tfvar_tmp

  apply_changes
}

get_zone_from_name() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

# advanced bash regardation
check_responding() {
  for try in {1..3}; do
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
