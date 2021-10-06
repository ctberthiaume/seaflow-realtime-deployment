variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "fileserver" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "0 */1 * * *"  // every hour
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "fileserver" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "fileserver" {
      driver = "exec"

      user = var.realtime_user

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        command = "/local/run.sh"
      }

      template {
        data = <<EOH
MC_HOST_minio="http://{{ key "minio/MINIO_ROOT_USER" }}:{{ key "minio/MINIO_ROOT_PASSWORD" }}@127.0.0.1:9000"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

fileserver_path="{{ key "caddy/fileserver_path" }}"
fileserver_file="{{ key "caddy/fileserver_file" }}"

# Copy from minio
[[ -d "$fileserver_path" ]] || mkdir -p "$fileserver_path"
mc cp "minio/data/$fileserver_file" "$fileserver_path/"
        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
