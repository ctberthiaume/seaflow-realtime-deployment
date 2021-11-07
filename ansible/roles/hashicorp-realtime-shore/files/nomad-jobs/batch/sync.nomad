variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "sync" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "30 * * * *"  // at 30 min past every hour
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "sync" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "sync" {
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
        destination = "/secrets/rclone.config"
        change_mode = "restart"
        perms = "644"
      }

      template {
        data = <<EOH
{{ key "sync/sshprivatekey" }}
        EOH
        destination = "/secrets/sshprivatekey"
        change_mode = "restart"
      }

      template {
        data = <<EOH
SYNC_HOST="{{ key "sync/host" }}"
CRUISE="{{ key "cruise/name" }}"
        EOH
        destination = "/local/file.env"
        env = true
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Sync to shore

set -e

# Convert \\n to true newlines in SSH private key file
# Would put this back in /secrets but can't write there from task
python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n", "\n"))' < /secrets/sshprivatekey > /local/sshprivatekey2
chmod 400 /local/sshprivatekey2

# Cache data to sync
rclone --log-level INFO --config /secrets/rclone.config copy --checksum minio:sync/ /jobs_data/sync/

# rsync to shore
# Make sure remote path exists
ssh -i /local/sshprivatekey2 -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" \
  "ubuntu@${SYNC_HOST}" \
  "bash -c 'mkdir ~/realtime-sync 2>/dev/null'"

rsync -e 'ssh -i /local/sshprivatekey2 -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null"' -au --stats \
  /jobs_data/sync/ \
  "ubuntu@${SYNC_HOST}:realtime-sync/${CRUISE}"

        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
