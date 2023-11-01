variable "realtime_user" {
  type    = string
  default = "ubuntu"
}

job "subsample" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron             = "10 */1 * * *" // every 1 hours at 10 past the hour
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }

  group "subsample" {
    count = 1

    # No restart attempts
    restart {
      attempts = 0
    }

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    task "setup" {
      driver = "exec"

      user = var.realtime_user

      config {
        command = "/local/run.sh"
      }

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      resources {
        memory = 50
        cpu    = 300
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

# Get job info
cruise="{{ key "cruise/name" }}"
start="{{ key "cruise/start" }}"
instrument=${NOMAD_META_instrument}
outdir=/jobs_data/subsample/${cruise}/${instrument}

echo "cruise=${cruise}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "start=${start}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "instrument=${instrument}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "outdir=${outdir}" >> ${NOMAD_ALLOC_DIR}/data/vars

# Get subsample parameters for this instrument as shell variable assignments
consul kv get -recurse "subsample/${NOMAD_META_instrument}/" | \
  awk -F':' '{split($1,a,"/"); print a[length(a)] "=" $2}' | \
  tee -a >> ${NOMAD_ALLOC_DIR}/data/vars
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms       = "755"
      }
    }

    task "subsample" {
      driver = "docker"

      config {
        image   = "ctberthiaume/seaflowpy:local"
        command = "/local/run.sh"
      }

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 2000
        cpu    = 300
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

seaflowpy version

# First get date range for last hour of EVT data
echo "$(date -u): EVT date range" 1>&2
timeout -k 60s 600s seaflowpy evt dates \
  --min-date "${start}" \
  --tail-hours "${sample_tail_hours}" \
  "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt" | tee "${NOMAD_ALLOC_DIR}/data/evt_dates" 1>&2
status=$?
if [[ ${status} -eq 124 ]]; then
  echo "$(date -u): evt dates killed by timeout sigint" 1>&2
elif [[ ${status} -eq 137 ]]; then
  echo "$(date -u): evt dates killed by timeout sigkill" 1>&2
elif [[ ${status} -gt 0 ]]; then
  echo "$(date -u): evt dates exited with an error, status = ${status}" 1>&2
else
  echo "$(date -u): evt dates completed successfully" 1>&2
fi

if [[ ! -s "${NOMAD_ALLOC_DIR}/data/evt_dates" ]]; then
  echo "$(date -u): No EVT data within date range" 1>&2
  exit
fi

mindate=$(awk '{print $1}' "${NOMAD_ALLOC_DIR}/data/evt_dates")
maxdate=$(awk '{print $2}' "${NOMAD_ALLOC_DIR}/data/evt_dates")

outdir="${outdir}/${mindate}"

# Full sample for noise estimation
if [[ ! -e "${outdir}/last-${sample_tail_hours}-hours.fullSample.parquet" ]]; then
  echo "$(date -u): Subsampling with no filters" 1>&2
  timeout -k 60s 600s seaflowpy evt sample \
    --min-date "${mindate}" \
    --max-date "${maxdate}" \
    --count "${sample_full_count}" \
    --file-fraction 1.0 \
    --verbose \
    --outpath "${outdir}/last-${sample_tail_hours}-hours.fullSample.parquet" \
    "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt" 1>&2
  status=$?
  if [[ ${status} -eq 124 ]]; then
    echo "$(date -u): full subsample killed by timeout sigint" 1>&2
  elif [[ ${status} -eq 137 ]]; then
    echo "$(date -u): full subsample killed by timeout sigkill" 1>&2
  elif [[ ${status} -gt 0 ]]; then
    echo "$(date -u): full subsample exited with an error, status = ${status}" 1>&2
  else
    echo "$(date -u): full subsample completed successfully" 1>&2
  fi
fi

# Bead sample
if [[ ! -e "${outdir}/last-${sample_tail_hours}-hours.beadSample.parquet" ]]; then
  echo "$(date -u): Subsampling for beads" 1>&2
  timeout -k 60s 600s seaflowpy evt sample \
    --min-date "${mindate}" \
    --max-date "${maxdate}" \
    --count 1500 \
    --noise-filter \
    --saturation-filter \
    --min-fsc "${bead_sample_min_fsc}" \
    --min-pe "${bead_sample_min_pe}" \
    --min-chl "${bead_sample_min_chl}"  \
    --multi --file-fraction 1.0 \
    --verbose \
    --outpath "${outdir}/last-${sample_tail_hours}-hours.beadSample.parquet" \
    "/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt" 1>&2
  status=$?
  if [[ ${status} -eq 124 ]]; then
    echo "$(date -u): bead subsample killed by timeout sigint" 1>&2
  elif [[ ${status} -eq 137 ]]; then
    echo "$(date -u): bead subsample killed by timeout sigkill" 1>&2
  elif [[ ${status} -gt 0 ]]; then
    echo "$(date -u): bead subsample exited with an error, status = ${status}" 1>&2
  else
    echo "$(date -u): bead subsample completed successfully" 1>&2
  fi
fi

# OPP sample
if [[ ! -e "${outdir}/${mindate}.1H.opp.sample.parquet" ]]; then
  echo "$(date -u): Subsampling OPP" 1>&2
  timeout -k 60s 600s seaflowpy opp sample \
    --min-date "${mindate}" \
    --max-date "${maxdate}" \
    --count "${opp_sample_count}" \
    --outpath "${outdir}/${mindate}.1H.opp.sample.parquet" \
    "/jobs_data/seaflow-analysis/${cruise}/${instrument}/${cruise}_opp"
  status=$?
  if [[ ${status} -eq 124 ]]; then
    echo "$(date -u): OPP subsample killed by timeout sigint" 1>&2
  elif [[ ${status} -eq 137 ]]; then
    echo "$(date -u): OPP subsample killed by timeout sigkill" 1>&2
  elif [[ ${status} -gt 0 ]]; then
    echo "$(date -u): OPP subsample exited with an error, status = ${status}" 1>&2
  else
    echo "$(date -u): OPP subsample completed successfully" 1>&2
  fi
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
        memory = 100
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

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

# Copy for sync to shore
echo "$(date): copying ${outdir} to minio:sync/subsample/${cruise}/${instrument}" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy \
  "${outdir}" \
  "minio:sync/subsample/${cruise}/${instrument}"

        EOH
        destination = "local/run.sh"
        perms       = "755"
        change_mode = "restart"
      }
    }
  }
}
