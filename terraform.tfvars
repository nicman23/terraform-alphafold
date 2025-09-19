vms = {
    "vm-01" = {
      machine_type = "g2-standard-4"
      spot_vm      = true,
      accelerator = {
        type  = "nvidia-l4"
        count = 1
      },
      work = "nvidia-smi > /tmp/a"
      zone = "europe-west4-c"
    }
  }
project_id = "optical-precept-472510-p2"