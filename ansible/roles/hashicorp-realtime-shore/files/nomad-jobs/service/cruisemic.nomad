variable "realtime_user" {
  type    = string
  default = "ubuntu"
}

job "cruisemic" {
  datacenters = ["dc1"]

  type = "service"

  group "cruisemic" {
    count = 1

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    service {
      name = "cruisemic"
    }

    task "cruisemic" {
      driver = "exec"

      user = var.realtime_user

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

CRUISE="{{ key "cruise/name" }}"
PARSER="{{ key "cruisemic/parser" }}"
PORT="{{ key "cruisemic/port" }}"
INTERVAL="{{ key "cruisemic/interval" }}"

cruisemic --version

cruisemic \
  -parser "${PARSER}" \
  -name "${CRUISE}" \
  -udp -port "${PORT}" \
  -interval "${INTERVAL}" \
  -raw \
  -dir "/jobs_data/cruisemic/${CRUISE}" \
  -quiet -flush
        EOH
        destination = "${NOMAD_TASK_DIR}/run.sh"
        perms       = "755"
        change_mode = "restart"
      }

      config {
        command = "${NOMAD_TASK_DIR}/run.sh"
      }
    }

    task "export" {
      driver = "raw_exec"

      user = var.realtime_user

      config {
        command = "${NOMAD_TASK_DIR}/run.sh"
      }

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 500
        cpu    = 300
      }

      template {
        data        = <<EOH
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
        destination = "${NOMAD_SECRETS_DIR}/rclone.config"
        change_mode = "restart"
        perms       = "644"
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

set -e

cruise="{{ key "cruise/name" }}"

while true; do
  # Copy for dashboard
  echo "$(date): uploading cruisemic files to minio:data/cruisemic/${cruise}/" 1>&2
  for f in /jobs_data/cruisemic/"${cruise}"/*.tab; do
    [[ ! -f "$f" ]] && continue
    [[ "$f" =~ .*-raw\.tab$ ]] && continue
    echo $(date): rclone --log-level INFO --config ${NOMAD_SECRETS_DIR}/rclone.config copy --checksum "$f" "minio:data/cruisemic/${cruise}/" 1>&2
    rclone --log-level INFO --config ${NOMAD_SECRETS_DIR}/rclone.config copy --checksum "$f" "minio:data/cruisemic/${cruise}/"
  done

  # Copy for sync to shore
  echo "$(date): uploading cruisemic files to minio:sync/cruisemic/${cruise}/" 1>&2
  for f in /jobs_data/cruisemic/"${cruise}"/*.tab; do
    [[ ! -f "$f" ]] && continue
    [[ "$f" =~ .*-raw\.tab$ ]] && continue
    echo $(date): rclone --log-level INFO --config ${NOMAD_SECRETS_DIR}/rclone.config copy --checksum "$f" "minio:sync/cruisemic/${cruise}/" 1>&2
    rclone --log-level INFO --config ${NOMAD_SECRETS_DIR}/rclone.config copy --checksum "$f" "minio:sync/cruisemic/${cruise}/"
  done

  sleep 5m
done

        EOH
        destination = "${NOMAD_TASK_DIR}/run.sh"
        perms       = "755"
        change_mode = "restart"
      }
    }
  }
}
