variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "changepoint" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "0 */1 * * *"  // every 1 hour
    prohibit_overlap = true
    time_zone = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }


  group "changepoint" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    # No restart attempts
    reschedule {
      attempts = 0
      unlimited = false
    }

    task "changepoint" {
      driver = "docker"

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image = "ctberthiaume/chapydette:local"
        command = "/local/run.sh"
      }

      resources {
        memory = 2000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Perform changepoint detection

set -e

findchangepoints --version

cruise="{{ key "cruise/name" }}"
instrument=${NOMAD_META_instrument}
outdir="/jobs_data/changepoint/${cruise}/${instrument}"
vctdir="/jobs_data/seaflow-analysis/${cruise}/${instrument}/${cruise}_vct"
dbfile="/jobs_data/seaflow-analysis/${cruise}/${instrument}/${cruise}.db"
cruisemicdir="/jobs_data/cruisemic/${cruise}"
usecruisemic="{{ key "changepoint/use_cruisemic" }}"

if [[ "${usecruisemic}" = "true" ]]; then
  phys="${cruisemicdir}"
else
  phys="${dbfile}"
fi

echo "cruise=${cruise}"
echo "instrument=${instrument}"
echo "outdir=${outdir}"
echo "vctdir=${vctdir}"
echo "dbfile=${dbfile}"
echo "cruisemicdir=${cruisemicdir}"
echo "usecruisemic=${usecruisemic}"
echo "phys=${phys}"

# Create output directory if it doesn't exist
if [[ ! -d "${outdir}" ]]; then
  echo "Creating output directory ${outdir}"
  mkdir -p "${outdir}" || exit $?
fi

findchangepoints --phys "${phys}" --vct-dir "${vctdir}" --out-dir "${outdir}" \
  --project "${cruise}" --filetype "changepoint_${instrument}"

        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
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
        destination = "/local/rclone.config"
        change_mode = "restart"
        perms = "644"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

cruise="{{ key "cruise/name" }}"
instrument=${NOMAD_META_instrument}
outdir="/jobs_data/changepoint/${cruise}/${instrument}"

# Copy for dashboard
echo "copying ${outdir}/cps.dates.phys.tsdata to minio:data/changepoint/"
rclone --config /local/rclone.config copy --checksum \
  "${outdir}/cps.dates.phys.tsdata" \
  "minio:data/changepoint/${cruise}/${instrument}/"
echo "copying ${outdir}/cps.dates.bio.tsdata to minio:data/changepoint/"
rclone --config /local/rclone.config copy --checksum \
  "${outdir}/cps.dates.bio.tsdata" \
  "minio:data/changepoint/${cruise}/${instrument}/"

# Copy for sync to shore
echo "copying ${outdir}/cps.dates.phys.tsdata to minio:sync/changepoint/"
rclone --config /local/rclone.config copy --checksum \
  "${outdir}/cps.dates.phys.tsdata" \
  "minio:sync/changepoint/${cruise}/${instrument}/"
echo "copying ${outdir}/cps.dates.bio.tsdata to minio:sync/changepoint/"
rclone --config /local/rclone.config copy --checksum \
  "${outdir}/cps.dates.bio.tsdata" \
  "minio:sync/changepoint/${cruise}/${instrument}/"

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }
    }
  }
}
