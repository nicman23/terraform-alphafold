terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

resource "google_compute_project_metadata" "serial_console" {
  metadata = {
    enable-serial-port-access = "true"
  }
}


# Define a map variable for VM instance configurations
variable "vms" {
  description = "A map of VM instance configurations to create."
  type = map(object({
      machine_type       = string
      cloud              = string
      spot_vm            = optional(bool, false)
      zone               = optional(string, "europe-north1-a")
      region             = optional(string, "europe-north1-a")
      auto_delete        = optional(bool, false)
      boot_image         = optional(string, "rocky-linux-accelerator-cloud/rocky-linux-9-optimized-gcp-nvidia-latest")
      boot_image_size    = optional(number, 50)
      boot_image_type    = optional(string, "pd-ssd")
      accelerator        = optional(object({
        type  = string
        count = number
      }))
  }))
}

variable "startup_script_file" {
  description = "Path to the startup script to be passed as user_data to AWS instances"
  default     = "./bootstrap.sh"
}

variable gcloud_project_id {
  default = "nop"
}

variable gcloud_project_key {
  default = "nop"
}

provider "google" {
  project = var.gcloud_project_id
  credentials = file(var.gcloud_project_key)
}

resource "google_compute_instance" "default" {

  for_each = { for k, v in var.vms : k => v if v.cloud == "gcloud" }

  name         = each.key
  machine_type = each.value.machine_type
  zone = try(each.value.zone, null)

  # Define the boot disk
  boot_disk {
    initialize_params {
      image = each.value.boot_image
      size = each.value.boot_image_size
      type = each.value.boot_image_type
    }
    auto_delete = each.value.auto_delete
  }

  # Define the network interface
  network_interface {
    network = "default"
    access_config {
      # This block allows the VM to have a public IP address
    }
  }

  # Conditionally configure the scheduling for Spot VMs
  dynamic "scheduling" {
    for_each = each.value.spot_vm ? [1] : []
    content {
      automatic_restart   = false
      on_host_maintenance = "TERMINATE"
      provisioning_model  = "SPOT"
      preemptible = true
    }
  }

  dynamic "scheduling" {
    for_each = each.value.spot_vm ? [] : [1]
    content {
      automatic_restart   = false
      on_host_maintenance = "TERMINATE"
      provisioning_model  = "STANDARD"
    }
  }

  # Conditionally configure the guest accelerator
  dynamic "guest_accelerator" {
    for_each = each.value.accelerator != null ? [each.value.accelerator] : []
    content {
      type  = guest_accelerator.value.type
      count = guest_accelerator.value.count
    }
  }

  lifecycle {
    ignore_changes = [
      scratch_disk,
      scheduling,
      boot_disk[0].initialize_params
    ]
  }

  # Use a startup script to run a simple bash command
  metadata_startup_script = file(var.startup_script_file)
 
}

# Output the public IP addresses of the VMs
output "public_ip_addresses" {
  value = [
    for instance in google_compute_instance.default : instance.network_interface[0].access_config[0].nat_ip
  ]
}
