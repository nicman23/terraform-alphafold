#!/bin/bash -e

# export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json \
export PATH="$(dirname $(realpath $0))/google-cloud-sdk/bin:$PATH"
DIRPATH="$(dirname $(realpath $0))"
tfvar=terraform.tfvars.json
tfvar_tmp=$DIRPATH/tmp_$tfvar
tfvar=$DIRPATH/$tfvar

source $DIRPATH/lib_gcloud.sh
# source $DIRPATH/lib_aws.sh

sssh() {
  ssh -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=15 -l root $(get_ip_from_name) "$@"
}

srsync() {
  rsync -r -e 'ssh -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5 -l root' $(get_ip_from_name):"$1" "$2"
}

apply_changes() {
  (
  cd $DIRPATH

  if terraform apply -var-file=$tfvar_tmp <<< yes ; then
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
  terraform refresh
  )
}

create_vm () {
  wait_for_lock
  touch $tfvar_tmp

  [ -z "$name" ] && name=vm-$(uuidgen)

  template=$1
  if [ ! -e "$DIRPATH/templates/${template}" ]; then
    echo please select from :
    ls $DIRPATH/templates/ | sed "s~$DIRPATH/templates/~~g"
    echo as a first arguement
  fi
  shift
  work="$@"
  machine_type=$(eval echo $(jq .machine_type < $DIRPATH/templates/${template}))

  success_file=$(mktemp -u)

  buf="$(get_sub_zones)"

  while [ ! -e $success_file ]; do
    echo "$buf" |
    while read zone; do
      jq --slurpfile vm <(jq '.work = "'"$work"'" | .zone = "'$zone'"' $DIRPATH/templates/${template}) '.vms["'$name'"] = $vm[0]' $tfvar > $tfvar_tmp
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

get_ip_from_name() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then select(.index_key == "'$name'") else empty end | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate

}

get_zone_from_name() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

check_responding() {
  cat << EOF | timeout 10 bash -
  $(type get_ip_from_name | sed 1d)

  $(type sssh | sed 1d)

  DIRPATH=$DIRPATH
  name=$name
  sssh true
EOF
}


list_defined() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then select(.index_key == "'$name'") else empty end | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate
}


list_running() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then .attributes.name else empty end' < $DIRPATH/terraform.tfstate
}
