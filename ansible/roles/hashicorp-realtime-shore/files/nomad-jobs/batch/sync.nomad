variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "sync" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "15 * * * *"  // at 15 min past every hour
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

      resources {
        memory = 50
        cpu = 300
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

# Convert \\n to true newlines in SSH private key file
# Would put this back in /secrets but can't write there from task
python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n", "\n"))' < /secrets/sshprivatekey > /local/sshprivatekey2
chmod 600 /local/sshprivatekey2

# Cache data to sync
echo "$(date -u): Caching data from minio:sync/" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum minio:sync/ /jobs_data/sync/
echo "$(date -u): Caching data from minio:user-data/" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum minio:user-data/ /jobs_data/sync/user-data

# rsync to shore
# Make sure remote path exists
echo "$(date -u): checking for shore sync target folder" 1>&2
ssh -i /local/sshprivatekey2 -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" \
  "ubuntu@${SYNC_HOST}" \
  "bash -c 'mkdir ~/realtime-sync 2>/dev/null'"

echo "$(date -u): rsync-ing data to shore" 1>&2
timeout 600s \
  rsync -e 'ssh -i /local/sshprivatekey2 -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null"' \
    -au --timeout 600 --progress --stats --bwlimit=300000 \
    /jobs_data/sync/ \
    "ubuntu@${SYNC_HOST}:realtime-sync/" 1>&2
status=$?
if [[ ${status} -eq 124 ]]; then
  echo "$(date -u): rsync killed by timeout sigint" 1>&2
elif [[ ${status} -eq 137 ]]; then
  echo "$(date -u): rsync killed by timeout sigkill" 1>&2
elif [[ ${status} -gt 0 ]]; then
  echo "$(date -u): rsync exited with an error, status = ${status}" 1>&2
else
  echo "$(date -u): rsync completed successfully" 1>&2
fi

exit ${status}

        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
