#!/bin/bash

zone=europe

get_sub_zones_aws() {
  local zones_file="${DIRPATH:-.}/.zones.aws.cache"

  for region in us-east-1; do
  # for region in $(aws ec2 describe-regions --query "Regions[].RegionName" --output text); do
    region_file="$zones_file"_"$region"
    if [ ! -f "$region_file" ] || [ "$(find "$region_file" -mtime +5 -print -quit)" ]; then
      aws ec2 describe-instance-type-offerings \
        --region "$region" \
        --location-type availability-zone \
        --output json > "$region_file"
    fi
    jq -r --arg mt "$machine_type" '.InstanceTypeOfferings[] | select(.InstanceType == $mt) | .Location' < "$region_file"
  done

}

get_ip_from_name_aws() {
  jq -r '.resources[].instances[] | if .schema_version == 1 then select(.index_key == "'$name'") else empty end | .attributes.public_ip' < $DIRPATH/terraform.tfstate

}

get_zone_from_name_aws() {
  jq -r '.vms."'$name'".zone' < $DIRPATH/terraform.tfvars.json
}

reset_vm_aws() {
  gcloud compute instances reset $name --zone=$zone
}

check_health_aws() {
  return 0
  cloud=aws
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


list_defined_aws() {
  jq -r '.resources[].instances[] | if .schema_version == 1 then select(.index_key == "'$name'") else empty end | .attributes.network_interface[0].access_config[0].nat_ip' < $DIRPATH/terraform.tfstate
}


list_running_aws() {
  jq -r '.resources[].instances[] | if .schema_version == 1 then .index_key else empty end' < $DIRPATH/terraform.tfstate | grep -v null
}
