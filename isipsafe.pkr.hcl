packer {
  required_version = ">= 1.10.0"
  required_plugins {
    digitalocean = {
      source  = "github.com/digitalocean/digitalocean"
      version = "~> 1.4"
    }
  }
}

variable "do_token" {
  type        = string
  default     = env("DIGITALOCEAN_TOKEN")
  sensitive   = true
  description = "DigitalOcean personal access token, read from DIGITALOCEAN_TOKEN."
}

variable "region" {
  type    = string
  default = "nyc3"
}

variable "size" {
  type        = string
  default     = "s-1vcpu-1gb"
  description = "Build on the smallest Droplet so the image works on every plan."
}

variable "base_image" {
  type    = string
  default = "ubuntu-24-04-x64"
}

variable "application_name" {
  type    = string
  default = "isIPsafe Protected Ubuntu"
}

variable "application_version" {
  type    = string
  default = "0.1.0"
}

variable "apt_packages" {
  type = list(string)
  default = [
    "ca-certificates",
    "curl",
    "fail2ban",
    "nftables",
    "python3",
    "python3-systemd",
    "python3-venv",
    "ufw",
    "unattended-upgrades",
  ]
}

locals {
  snapshot_name = "isipsafe-ubuntu-24-04-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  apt_env = [
    "DEBIAN_FRONTEND=noninteractive",
    "LC_ALL=C",
    "LANG=en_US.UTF-8",
    "LC_CTYPE=en_US.UTF-8",
  ]
}

source "digitalocean" "isipsafe" {
  api_token     = var.do_token
  image         = var.base_image
  region        = var.region
  size          = var.size
  ssh_username  = "root"
  snapshot_name = local.snapshot_name
  droplet_name  = "isipsafe-image-build"
  tags          = ["isipsafe-image-build"]
}

build {
  name    = "isipsafe-protected-ubuntu"
  sources = ["source.digitalocean.isipsafe"]

  provisioner "shell" {
    inline           = ["cloud-init status --wait"]
    valid_exit_codes = [0, 2]
  }

  provisioner "file" {
    source      = "files/etc/"
    destination = "/etc/"
  }

  provisioner "file" {
    source      = "files/opt/"
    destination = "/opt/"
  }

  provisioner "file" {
    source      = "files/var/"
    destination = "/var/"
  }

  provisioner "shell" {
    environment_vars = local.apt_env
    inline = [
      "apt-get -qq update",
      "apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' full-upgrade",
      "apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' install ${join(" ", var.apt_packages)}",
      "apt-get -qqy clean",
    ]
  }

  provisioner "shell" {
    environment_vars = concat(local.apt_env, [
      "application_name=${var.application_name}",
      "application_version=${var.application_version}",
    ])
    scripts = [
      "scripts/01-isipsafe.sh",
      "scripts/02-hardening.sh",
      "scripts/90-cleanup.sh",
      "scripts/99-img-check.sh",
    ]
  }
}
