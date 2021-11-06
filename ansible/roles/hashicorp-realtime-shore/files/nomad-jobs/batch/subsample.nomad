variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "subsample" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "10 */4 * * *"  // every 4 hours at 10 past the hour
    prohibit_overlap = true
    time_zone = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "subsample" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "setup" {
      driver = "exec"

      user = var.realtime_user

      config {
        command = "/local/run.sh"
      }

      lifecycle {
        hook = "prestart"
        sidecar = false
      }

      resources {
        memory = 300
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

# Get cruise info
echo "cruise=$(consul kv get cruise/name)" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "start=$(consul kv get cruise/start)" >> ${NOMAD_ALLOC_DIR}/data/vars

# Get instrument name
echo "instrument=${NOMAD_META_instrument}" >> ${NOMAD_ALLOC_DIR}/data/vars

timestamp="$(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)"
echo "timestamp=$(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)"  >> ${NOMAD_ALLOC_DIR}/data/vars
echo "outdir=/jobs_data/subsample/${cruise}/${instrument}/${timestamp}" >> ${NOMAD_ALLOC_DIR}/data/vars

# Get subsample parameters for this instrument as shell variable assignments
consul kv get -recurse "subsample/${NOMAD_META_instrument}/" | \
  awk -F':' '{split($1,a,"/"); print a[length(a)] "=" $2}' | \
  tee -a >> ${NOMAD_ALLOC_DIR}/data/vars
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "subsample" {
      driver = "docker"

      config {
        image = "ctberthiaume/seaflowpy:local"
        command = "/local/run.sh"
      }

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 2000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

seaflowpy version

[[ -d "$outdir" ]] || mkdir -p "$outdir"

# Full sample for noise estimation
seaflowpy evt sample \
  --min-date "${start}" \
  --tail-hours "${sample_tail_hours}" \
  --count "${sample_noise_count}" \
  --file-fraction 1.0 \
  --verbose \
  --outpath "${outdir}/last-${sample_tail_hours}-hours.fullSample.parquet" \
  "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"

# Full sample with noise filtered out
seaflowpy evt sample \
  --min-date "${start}" \
  --tail-hours "${sample_tail_hours}" \
  --noise-filter \
  --file-fraction 1.0 \
  --count "${sample_full_count}" \
  --verbose \
  --outpath "${outdir}/last-${sample_tail_hours}-hours.fullSample-noNoise.parquet" \
  "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"

# Bead sample
seaflowpy evt sample \
  --min-date "${start}" \
  --tail-hours "${sample_tail_hours}" \
  --count 1500 \
  --noise-filter \
  --min-fsc "${bead_sample_min_fsc}" \
  --min-pe "${bead_sample_min_pe}" \
  --min-chl "${bead_sample_min_chl}"  \
  --multi --file-fraction 1.0 \
  --verbose \
  --outpath "${outdir}/last-${sample_tail_hours}-hours.beadSample.parquet" \
  "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"

# Bead finder
seaflowpy evt beads \
  --cruise "${cruise}" \
  --min-fsc "${bead_finder_min_fsc}" \
  --min-pe "${bead_finder_min_pe}" \
  --verbose \
  --out-dir "${outdir}/last-${sample_tail_hours}-hours.beads" \
  "${outdir}/last-${sample_tail_hours}-hours.beadSample.parquet"

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

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

# Copy for sync to shore
echo "copying ${outdir} to minio:sync/subsample/${outdir}"
rclone --log-level INFO --config /local/rclone.config copy --checksum \
  "${outdir}" \
  "minio:sync/subsample/${cruise}/${instrument}/${timestamp}"

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }
    }
  }
}
