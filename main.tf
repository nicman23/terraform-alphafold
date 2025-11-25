terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable project_id {
  default = "nop"
}

variable project_key {
  default = "nop"
}

provider "google" {
  project = var.project_id
  credentials = file(var.project_key)
}

# Define a map variable for VM instance configurations
variable "vms" {
  description = "A map of VM instance configurations to create."
  type = map(object({
    machine_type       = string
    spot_vm            = optional(bool, false)
    work               = optional(string, "true")
    zone               = optional(string, "europe-north1-a")
    auto_delete        = optional(bool, false)
    boot_image         = optional(string, "rocky-linux-accelerator-cloud/rocky-linux-9-optimized-gcp-nvidia-latest")
    boot_image_size    = optional(number, 50)
    accelerator        = optional(object({
      type  = string
      count = number
    }))
  }))
  default = {
    "vm-01" = {
      machine_type = "e2-medium"
      spot_vm      = true
      zone         = "us-central1-a"
      work = "apt update && apt install -y htop"
    },
    "vm-02" = {
      machine_type = "n1-standard-4"
      accelerator = {
        type  = "nvidia-tesla-t4"
        count = 1
      }
    }
  }
}

# Define a variable for the custom message
variable "welcome_message" {
  description = "The welcome message to display in the VM startup script."
  type        = string
  default     = "Hello from Terraform!"
}

# # Add a resource to request an increase to the GPU quota
# resource "google_cloud_quotas_quota_preference" "gpu_quota_request" {
#   # The parent for this resource is the project
#   parent = "projects/optical-precept-472510-p2"

#   # The service for the GPU quota
#   service = "compute.googleapis.com"

#   # The specific quota ID for all-region GPUs
#   quota_id = "GPUS-ALL-REGIONS-per-project"

#   # The preferred value for the quota. A value of 1 is requested here.
#   quota_config {
#     preferred_value = 2
#   }

#   # A justification for the quota request
#   justification = "Required for a personal machine learning project."

#   # An optional contact email for communication about the request
#   contact_email = "your-email@example.com"
# }

# Create multiple VM instances
resource "google_compute_instance" "default" {


  for_each     = var.vms
  name         = each.key
  machine_type = each.value.machine_type

  zone = try(each.value.zone, null)

  # Define the boot disk
  boot_disk {
    initialize_params {
      image = each.value.boot_image
      size = each.value.boot_image_size
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
      scheduling
    ]
  }

  # Use a startup script to run a simple bash command
  metadata_startup_script = <<-EOF
  #!/bin/bash


  while ! ping -c 1 1.1.1.1; do
    sleep 1
  done

  mkdir -p /root/.ssh
  echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDEGnYuS8YZh+eUlHsMdfmzyGCtiz2ZDZhc0TgeHAx8SFAbkB5+jT9JG6a2/ZlrfsNzpTD9n2SF2N+NKmm+TfjQiMIeL39JbDNc+DRGccJsleY5xP3L1CH6yL3/nbw1CBgCcVchWRu8wejUQzesGiH/ZXLIjHqMhjsHQ8OeBo1mnz5i8McqQGuzbyFWVe5Y+KrSXYyAL3bHYCjWRPI18vgIAdAsVl1EX+hebMSvp99ZuspP/j4X7KkRWxVdydMzkRaQsaGEy8jb5u+rBId9iOxx5r5Ts/r9NfhmSD/6Kn26+h+CK1NhZqXb4qj0gfkq4iWMzmTo9oJD1R+b8aoz3/Fr nikos" > /root/.ssh/authorized_keys
  echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDSHzH2Vn+fS1okGupLvU4kSvzWD03VGr6u7mT2jysI8p6BReeQheMl9FADMSekmVdn/uCb1cyHT9Y3rMa2N9rbsA/blPwAXLot/xj1iYQ+lFDfWvyaNNVxbSmRU3TKxms985Vh4WR8XN0X/olLI/eNdWVkqNUSmADgVCDgIZ5CTDXCT9gqrBfXSjYwK6ifzqWyfUDavbu4er9A5nS5iEmQMwrR7GQFR5Z+RtCpne+bUaZCaJNdFxxaP7OIjffCFlTZgXNvxdqmJc02vmvgZKeaPQuR7fZw0Dl3nVz+6wE3ztd0yFXJtIod4kLwgYkNh8dkQRrnIzkwqdthV5ou5HbyKWfJKTsVRK18I5Aylv7ddLOJSO+T8i4yU3Tjdp/Txh4tZFIFZDeRn0ru8f2DoUMnCRhpngcF6Iipgp/1wCf3ucPko2fRCEun20Yub0g83Q578Iy6f+HB/URE1t3l8twH+Rk2ErO6fcHRzeL2onfiuUjSdtqH49YqvAkTu3azF4E= katsila-lab"  >> /root/.ssh/authorized_keys
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSLeRrR7pw9eZ2tWxx+g2GKCz1WaHv+SA19jV8YPtKZ NAS"  >> /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys

  sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config
  sed -i -r 's/PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart ssh ||
  systemctl restart sshd # rhel
  docker ||
  (
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
    tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf config-manager --enable nvidia-container-toolkit-experimental

    dnf install -y \
        nvidia-container-toolkit \
        nvidia-container-toolkit-base \
        libnvidia-container-tools \
        libnvidia-container1

    systemctl enable --now docker
  ) &> /tmp/install
  ${each.value.work}
  EOF
}

# Output the public IP addresses of the VMs
output "public_ip_addresses" {
  value = [
    for instance in google_compute_instance.default : instance.network_interface[0].access_config[0].nat_ip
  ]
}
