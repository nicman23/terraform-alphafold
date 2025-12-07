terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
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
  metadata_startup_script = file(var.startup_script_file)
 
}

# Output the public IP addresses of the VMs
output "public_ip_addresses" {
  value = [
    for instance in google_compute_instance.default : instance.network_interface[0].access_config[0].nat_ip
  ]
}

# Configure AWS providers for multiple regions
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "default"
  region = "us-east-1"
}

resource "aws_vpc" "default" {
  provider             = aws.default
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "permissive-default-vpc"
  }
}

resource "aws_subnet" "public" {
  provider                = aws.default
  vpc_id                  = aws_vpc.default.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "permissive-default-subnet"
  }
}

resource "aws_internet_gateway" "gw" {
  provider = aws.default
  vpc_id   = aws_vpc.default.id

  tags = {
    Name = "permissive-default-igw"
  }
}

resource "aws_route_table" "public" {
  provider = aws.default
  vpc_id   = aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "permissive-default-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  provider      = aws.default
  subnet_id     = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "permissive" {
  provider    = aws.default
  name        = "permissive-default-sg"
  description = "Allow all inbound and outbound traffic"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "permissive-default-sg"
  }
}

resource "aws_network_acl" "permissive" {
  provider = aws.default
  vpc_id   = aws_vpc.default.id

  ingress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "permissive-default-nacl"
  }
}

resource "aws_network_acl_association" "public_assoc" {
  provider     = aws.default
  subnet_id    = aws_subnet.public.id
  network_acl_id = aws_network_acl.permissive.id
}

# Create AWS EC2 instances for vms that target AWS
resource "aws_instance" "default" {
  for_each = { for k, v in var.vms : k => v if v.cloud == "aws" }

  # provider    = local.aws_providers[each.value.region]
  ami           = each.value.boot_image
  instance_type = each.value.machine_type
  availability_zone = each.value.zone
  associate_public_ip_address = true

  root_block_device {
    volume_size           = each.value.boot_image_size
    delete_on_termination = each.value.auto_delete
  }

  # Spot instances on AWS are configured via instance_market_options.
  # Vendor difference: AWS uses spot market options instead of GCP scheduling.provisioning_model.
  dynamic "instance_market_options" {
    for_each = each.value.spot_vm ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        # Set interruption behaviour similar to GCP's preemptible/spot semantics.
        instance_interruption_behavior = "terminate"
        # Additional spot options (max_price, spot_instance_type) may be added here.
      }
    }
  }
  # Use a startup script to run a simple bash command
  user_data = file(var.startup_script_file)

  tags = {
    Name = each.key
  }

  # Select AWS availability zone from the VM's zone field (if provided)
  subnet_id               = aws_subnet.public.id
  vpc_security_group_ids  = [aws_security_group.permissive.id]

  lifecycle {
    ignore_changes = [
      # user_data changes commonly cause a replacement; ignore if you prefer not to trigger replacements.
      user_data
    ]
  }
}