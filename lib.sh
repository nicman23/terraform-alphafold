#!/bin/bash -e

export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json \
PATH="$(dirname $(realpath $0))/google-cloud-sdk/bin:$PATH"
DIRPATH="$(dirname $(realpath $0))"
tfvar=terraform.tfvars.json
tfvar_tmp=$DIRPATH/tmp_$tfvar
tfvar=$DIRPATH/$tfvar
zone=europe

sssh() {
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l root "$@"
}

srsync() {
  rsync -e 'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l root' "$@"
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

  buf="$(gcloud compute machine-types list --filter=$machine_type | grep $zone | awk '{print $2}' )"

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
  jq -r '.resources[].instances[] | select(.index_key == "'$name'") | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate

}

get_zone_from_name() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

check_health() {
  zone=$(get_zone_from_name)
  status=$(gcloud compute instances describe "$name" --zone="$zone" --format='get(status)' 2>/dev/null)

  case "$status" in
    RUNNING)
      echo $name is running 2> /dev/null
      return 0
        ;;
    TERMINATED)
      echo $name was down\; starting 2> /dev/null
      gcloud compute instances start "$name" --zone="$zone"
        ;;
    *)
      echo $status; echo trye
      sleep 10;
      status=$(gcloud compute instances describe "$name" --zone="$zone" --format='get(status)' 2>/dev/null)
        ;;
  esac

}


list_defined() {
  jq -r '.resources[].instances[].index_key' < $DIRPATH/terraform.tfstate
}


list_running() {
  jq -r '.resources[].instances[].index_key' < $DIRPATH/terraform.tfstate
}
