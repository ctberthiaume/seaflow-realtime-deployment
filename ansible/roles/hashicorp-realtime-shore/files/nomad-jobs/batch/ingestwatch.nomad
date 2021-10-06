variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "ingestwatch" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/15 * * * *"  // every 15 minutes
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "ingestwatch" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "ingestwatch" {
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
[minio]
type = s3
provider = Minio
env_auth = false
access_key_id = {{ key "minio/MINIO_ROOT_USER" }}
secret_access_key = {{ key "minio/MINIO_ROOT_PASSWORD" }}
region = us-east-1
endpoint = http://127.0.0.1:9000
location_constraint =
server_side_encryption =

        EOH
        destination = "/local/rclone.config"
        change_mode = "restart"
        perms = "644"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

# Copy to minio
find "/jobs_data/ingestwatch" \
  -type f -name "*.tsdata" \
  -exec bash -c "echo copying {} to minio/data; rclone --config /local/rclone.config copy --checksum {} minio:data/" \;

        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
