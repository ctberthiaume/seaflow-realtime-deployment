variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "ingestwatch" {
  datacenters = ["dc1"]

  type = "service"

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
#!/usr/bin/env bash

cruise={{ key "cruise/name" }}

while true; do
  # Copy files in ingestwatch to minio
  if [[ -d /jobs_data/ingestwatch ]]; then
    echo "$(date): copying /jobs_data/ingestwatch/*.tsdata to minio/data" 1>&2
    find /jobs_data/ingestwatch \
      -type f -name "*.tsdata" \
      -exec bash -c "echo $(date): copying {} to minio/data 1>&2; rclone --log-level INFO --config /secrets/rclone.config copy --checksum {} minio:data/" \;
  else
    echo "$(date): /jobs_data/ingestwatch not present, skipping upload" 1>&2
  fi

  # Copy cruisemic to minio
  geofile=/jobs_data/cruisemic/${cruise}/${cruise}-geo.tab
  if [[ -e "${geofile}" ]]; then
    echo "$(date): copying ${geofile} to minio/data/cruisemic/${cruise}/" 1>&2
    rclone --log-level INFO --config /secrets/rclone.config copy --checksum ${geofile} minio:data/cruisemic/${cruise}/
    echo "$(date): copying ${geofile} to minio/sync/cruisemic/${cruise}/" 1>&2
    rclone --log-level INFO --config /secrets/rclone.config copy --checksum ${geofile} minio:sync/cruisemic/${cruise}/
  else
    echo "$(date): ${geofile} not present, skipping upload" 1>&2
  fi

  sleep {{ key "ingestwatch/interval" }}
done

        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
