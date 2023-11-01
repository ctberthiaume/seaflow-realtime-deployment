variable "realtime_user" {
  type    = string
  default = "ubuntu"
}

job "seaflow-diagnostics" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron             = "*/10 * * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }

  group "seaflow-diagnostics" {
    count = 1

    # No restart attempts
    restart {
      attempts = 0
    }

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    task "seaflog" {
      driver = "exec"

      user = var.realtime_user

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      template {
        data        = <<EOH
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
        perms       = "755"
        change_mode = "restart"
      }

      config {
        command = "/local/run.sh"
      }
    }

    task "drift-and-background" {
      driver = "docker"

      config {
        image   = "ctberthiaume/popcycle:local"
        command = "/local/run.sh"

        mount {
          type   = "bind"
          target = "/jobs_data"
          source = "/jobs_data"
          volume_options {
            no_copy = true
          }
        }

        mount {
          type     = "bind"
          target   = "/scripts"
          source   = "/etc/realtime/scripts"
          readonly = true
          volume_options {
            no_copy = true
          }
        }
      }

      resources {
        memory = 4000
        cpu    = 300
      }

      template {
        data        = <<EOH
CRUISE="{{key "cruise/name"}}"
INSTRUMENT="${NOMAD_META_instrument}"
        EOH
        destination = "${NOMAD_TASK_DIR}/file.env"
        env         = true
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash
# Perform SeaFlow diagnostics on subsampled bead data and unknown particle classifications

set -e

cruise="{{ key "cruise/name" }}"
instrument="${NOMAD_META_instrument}"

drift_file="/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/drift.${cruise}.${instrument}.tsdata"
background_file="/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/background.${cruise}.${instrument}.tsdata"
subsample_dir="/jobs_data/subsample/${cruise}/${instrument}/"
stats_file="/jobs_data/seaflow-analysis/${cruise}/${instrument}/stats-no-abund.${cruise}.${instrument}.tsdata"

Rscript --slave -e 'message(packageVersion("popcycle"))'

# Classify and produce summary image files
echo "$(date -u): Generating SeaFlow diagnostic data" >&2
timeout -k 60s 2h \
Rscript --slave /scripts/realtime-diagnostics.R \
  --instrument "${instrument}" \
  --cruise "${cruise}" \
  --subsample-dir "${subsample_dir}" \
  --stats-file "${stats_file}" \
  --drift-file "${drift_file}" \
  --background-file "${background_file}"
status=$?
if [[ ${status} -eq 124 ]]; then
  echo "$(date -u): diagnostics killed by timeout sigint" 1>&2
elif [[ ${status} -eq 137 ]]; then
  echo "$(date -u): diagnostics killed by timeout sigkill" 1>&2
elif [[ ${status} -gt 0 ]]; then
  echo "$(date -u): diagnostics exited with an error, status = ${status}" 1>&2
else
  echo "$(date -u): diagnostics completed successfully" 1>&2
fi
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms       = "755"
      }
    }

    task "export" {
      driver = "exec"

      user = var.realtime_user

      config {
        command = "/local/run.sh"
      }

      lifecycle {
        hook    = "poststop"
        sidecar = false
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
        destination = "/secrets/rclone.config"
        change_mode = "restart"
        perms       = "644"
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

set -e

cruise="{{ key "cruise/name" }}"
instrument="${NOMAD_META_instrument}"

# Copy for dashboard data
echo "$(date): copying /jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata to minio:data/seaflog/${cruise}/${instrument}/" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata" \
  minio:data/seaflog/${cruise}/${instrument}/

echo "$(date): copying /jobs_data/seaflow-diagnostics/${cruise}/${instrument}/drift.${cruise}.${instrument}.tsdata to minio:data/seaflow-diagnostics" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/drift.${cruise}.${instrument}.tsdata" \
  minio:data/seaflow-diagnostics/${cruise}/${instrument}/

echo "$(date): copying /jobs_data/seaflow-diagnostics/${cruise}/${instrument}/background.${cruise}.${instrument}.tsdata to minio:data/seaflow-diagnostics" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/background.${cruise}.${instrument}.tsdata" \
  minio:data/seaflow-diagnostics/${cruise}/${instrument}/

# Copy for sync to shore
echo "$(date): copying /jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata to minio:sync/seaflog/${cruise}/${instrument}/" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflog/${cruise}/${instrument}/seaflog.${cruise}.${instrument}.tsdata" \
  minio:sync/seaflog/${cruise}/${instrument}/

echo "$(date): copying /jobs_data/seaflow-diagnostics/${cruise}/${instrument}/drift.${cruise}.${instrument}.tsdata to minio:sync/seaflow-diagnostics" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/drift.${cruise}.${instrument}.tsdata" \
  minio:sync/seaflow-diagnostics/${cruise}/${instrument}/

echo "$(date): copying /jobs_data/seaflow-diagnostics/${cruise}/${instrument}/background.${cruise}.${instrument}.tsdata to minio:sync/seaflow-diagnostics" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/seaflow-diagnostics/${cruise}/${instrument}/background.${cruise}.${instrument}.tsdata" \
  minio:sync/seaflow-diagnostics/${cruise}/${instrument}/
        EOH
        destination = "local/run.sh"
        perms       = "755"
        change_mode = "restart"
      }
    }
  }
}
