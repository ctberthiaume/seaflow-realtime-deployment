variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "seaflog" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/10 * * * *"
    prohibit_overlap = true
    time_zone = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }

  group "seaflog" {
    count = 1

    # No restart attempts
    restart {
      attempts = 0
    }

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "parse" {
      driver = "exec"

      user = var.realtime_user

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

cruise="{{ key "cruise/name" }}"
start="{{ key "cruise/start" }}"
end="{{ key "cruise/end" }}"
instrument="${NOMAD_META_instrument}"

seaflog --version

seaflog \
  --filetype SeaFlowInstrumentLog_${instrument} \
  --project "${cruise}" \
  --description "SeaFlow Instrument Log data for ${cruise} bewteen ${start} and ${end}" \
  --earliest "${start}" \
  --latest "${end}" \
  --logfile "/jobs_data/seaflow-transfer/${cruise}/${instrument}/SFlog.txt" \
  --outfile "/jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata" \
  --quiet

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }

      config {
        command = "/local/run.sh"
      }
    }

    task "export" {
      driver = "exec"

      user = var.realtime_user

      config {
        command = "/local/run.sh"
      }

      lifecycle {
        hook = "poststop"
        sidecar = false
      }

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 500
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

set -e

cruise="{{ key "cruise/name" }}"
instrument="${NOMAD_META_instrument}"

# Copy for dashboard data
echo "$(date): copying /jobs_data/seaflog/${cruise}/${instrument}/${cruise}.${instrument}.tsdata to minio:data/seaflog/${cruise}.${instrument}.tsdata" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata" \
  minio:data/seaflog/${cruise}/${instrument}/

# Copy for sync to shore
echo "$(date): copying /jobs_data/seaflog/${cruise}/${instrument}/${cruise}.${instrument}.tsdata to minio:sync/seaflog/${cruise}.${instrument}.tsdata" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata" \
  minio:sync/seaflog/${cruise}/${instrument}/

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }
    }
  }
}
