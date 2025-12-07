#!/bin/bash -e

zone=europe
# export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json \

get_sub_zones_gcloud() {
  zones_file="${DIRPATH:-.}/.zones.gcloud.cache"
  if [ ! -f "$zones_file" ] || [ "$(find "$zones_file" -mtime +5 -print -quit)" ]; then
    echo "Refreshing zones cache: $zones_file" >&2
    gcloud compute machine-types list > "$zones_file"
  else
    echo "Using cached zones file: $zones_file" >&2
  fi
  cat "$zones_file" | grep $machine_type | grep $zone | awk '{print $2}'
}

get_ip_from_name_gcloud() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then select(.index_key == "'$name'") else empty end | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate

}

get_zone_from_name_gcloud() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

reset_vm_gcloud() {
  gcloud compute instances reset $name --zone=$zone
}

check_health_gcloud() {
  zone=$(get_zone_from_name)
  status=$(gcloud compute instances describe "$name" --zone="$zone" --format='get(status)' 2>/dev/null)

  case "$status" in
    RUNNING)
      if check_responding; then
        echo is running 2> /dev/null
      else
        echo is not responding - reseting
        reset_vm & disown
      fi
      return 0
        ;;
    TERMINATED)
      echo was down\; starting 2> /dev/null
      gcloud compute instances start "$name" --zone="$zone"
        ;;
    *)
      echo invalid state "$status";
      sleep 10;
      status=$(gcloud compute instances describe "$name" --zone="$zone" --format='get(status)' 2>/dev/null)
        ;;
  esac

}


list_defined_gcloud() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then select(.index_key == "'$name'") else empty end | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate
}


list_running_gcloud() {
  jq -r '.resources[].instances[] | if .schema_version == 6 then .attributes.name else empty end' < $DIRPATH/terraform.tfstate
}
