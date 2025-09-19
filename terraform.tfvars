vms = {
    "vm-01" = {
      machine_type = "f1-micro"
      work = "apt update && apt install -y htop"
    },
    "vm-02" = {
      machine_type = "n1-standard-4"
      spot_vm      = true,
      accelerator = {
        type  = "nvidia-tesla-t4"
        count = 1
      },
      work = "nvidia-smi > /tmp/a"
    }
  }
project_id = "optical-precept-472510-p2"