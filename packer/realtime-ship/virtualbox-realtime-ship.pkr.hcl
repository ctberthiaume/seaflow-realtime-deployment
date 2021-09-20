variable "ssh_private_key_file" {
  type        = string
  description = "SSH private key file to use for default user"
  default = null
  validation {
    condition     = fileexists(var.ssh_private_key_file)
    error_message = "The ssh_private_key_file must exist."
  }
}

# Can be generated from private key with
# ssh-keygen -y -f private_key_file | awk '{print $1, $2}' > public_key_file
variable "ssh_public_key_file" {
  type        = string
  description = "SSH public key file to use for default user"
  default = null
  validation {
    condition     = fileexists(var.ssh_public_key_file)
    error_message = "The ssh_public_key_file must exist."
  }
}

variable "host_ssh_port" {
  type        = string
  description = "SSH port on host to connect to VM SSH server"
  default     = "2020"
}

locals {
  memory    = "10240"
  cpus      = "2"
  disk_size = 100000
  build_memory = "1024"
  build_cpus = "1"
  ssh_public_key = join(" ", slice(split(" ", file("${var.ssh_public_key_file}")), 0, 2))
}

source "virtualbox-iso" "realtime-ship" {
  guest_os_type    = "Ubuntu_64"
  headless         = false
  iso_url          = "https://releases.ubuntu.com/20.04.3/ubuntu-20.04.3-live-server-amd64.iso"
  iso_checksum     = "sha256:f8e3086f3cea0fb3fefb29937ab5ed9d19e767079633960ccb50e76153effc98"
  ssh_username     = "ubuntu"
  ssh_password     = "ubuntu"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_handshake_attempts = "20"
  shutdown_command = "echo 'ubuntu' | sudo -S shutdown -P now"
  http_content = {
    "/user-data" = templatefile("${path.root}/autoinstall/user-data.pkrtpl", { ssh_public_key = local.ssh_public_key } )
    "/meta-data" = ""
  }
  cpus = local.build_cpus
  memory = local.build_memory
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--memory", local.memory],
    ["modifyvm", "{{.Name}}", "--cpus", local.cpus],
    ["modifyvm", "{{.Name}}", "--natpf1", "sshforward,tcp,,${var.host_ssh_port},,22"]
  ]
  disk_size = local.disk_size
  boot_wait = "5s"
  boot_command = [
    "<enter><enter><f6><esc><wait>",
    "autoinstall ip=dhcp ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<enter>",
  ]
  format = "ova"
}

build {
  sources = [
    "source.virtualbox-iso.realtime-ship"
  ]
  // provisioner ansible {
  //   user          = "ubuntu"
  //   command       = "./run-ansible.sh"
  //   playbook_file = "../ansible/playbook-test.yml"
  // }
}
