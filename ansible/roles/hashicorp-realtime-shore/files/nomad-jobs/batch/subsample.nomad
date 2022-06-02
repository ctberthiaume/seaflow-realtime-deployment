variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "subsample" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "10 */1 * * *"  // every 1 hours at 10 past the hour
    prohibit_overlap = true
    time_zone = "UTC"
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
        memory = 50
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

# Get job info
cruise="{{ key "cruise/name" }}"
start="{{ key "cruise/start" }}"
instrument=${NOMAD_META_instrument}
timestamp="$(TZ=UTC date +%Y-%m-%dT%H:%M:%SZ)"
outdir=/jobs_data/subsample/${cruise}/${instrument}/${timestamp}

echo "cruise=${cruise}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "start=${start}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "instrument=${instrument}" >> ${NOMAD_ALLOC_DIR}/data/vars
echo "timestamp=${timestamp}"  >> ${NOMAD_ALLOC_DIR}/data/vars
echo "outdir=${outdir}" >> ${NOMAD_ALLOC_DIR}/data/vars

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
        memory = 5000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env python3
# Sample from OPP parquet for previous hour

import datetime
import glob
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import click
import pandas as pd
import seaflowpy.seaflowfile as sfile

logging.basicConfig(format='%(asctime)s: %(message)s', level=logging.INFO, datefmt="%Y-%m-%dT%H:%M:%S%z")


@click.command()
@click.option("--count", type=int, default=100000, help="Maximum number of particles to subsample")
@click.option("--seed", type=int, help="Random state seed for reproducibility")
@click.argument("oppdir", type=click.Path(exists=True, dir_okay=True, file_okay=False, readable=True))
@click.argument("outdir", type=click.Path(exists=False, dir_okay=True, file_okay=False))
def cli(count, seed, oppdir, outdir):
    logging.info("count=%d seed=%s oppdir=%s outdir=%s", count, seed, oppdir, outdir)

    opps = []
    for o in sorted(glob.glob(f"{oppdir}/*.parquet")):
      parts = os.path.basename(o).split(".")[0].split("T")
      parts[1] = parts[1].replace("-", ":")
      opps.append({
        "filename": os.path.basename(o),
        "path": o,
        "date": datetime.fromisoformat("T".join(parts))
      })

    now = datetime.now(timezone.utc)
    prevhour = (now - timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)
    
    logging.info("current time is %s, last hour was %s", now.isoformat(), prevhour.isoformat())
    
    matches = [o for o in opps if o["date"] == prevhour]
    if len(matches) == 0:
      logging.info("no OPP files found for the previous hour")
    elif len(matches) > 1:
      logging.warning("> 1 OPP file found for the previous hour: %s", ", ".join([m["filename"] for m in matches]))
    else:
      input_file = matches[0]
      logging.info("found OPP file for the previous hour: %s", input_file["filename"])
      output_path = os.path.join(outdir, input_file["filename"].replace(".parquet", "") + ".sample.parquet")
      logging.info("writing to %s", output_path)
      if not os.path.exists(output_path):
        try:
          os.makedirs(outdir, exist_ok=True)
        except OSError as e:
          logging.error("could not create output directory %s: %s", outdir, e)
          sys.exit(1)

        try:
          df = pd.read_parquet(input_file["path"])
        except (IOError, OSError) as e:
          logging.error("could not read parquet file %s: %s", input_file["path"], e)
          sys.exit(1)
        count = min(count, len(df))
        if seed is not None:
          sub = df.sample(n=count, random_state=seed)
        else:
          sub = df.sample(n=count)
        logging.info("sampled %d / %d rows", len(sub), len(df))
        try:
          sub.to_parquet(output_path)
        except (IOError, OSError) as e:
          logging.error("could not write parquet file %s: %s", output_path, e)
          sys.exit(1)
      else:
        logging.info("output file %s already exists, skipping", output_path)


if __name__ == "__main__":
    cli(auto_envvar_prefix='SAMPLE')

        EOH
        destination = "/local/sample.py"
        perms = "755"
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
echo "$(date -u): Subsampling with no filters" 1>&2
timeout -k 60s 600s seaflowpy evt sample \
  --min-date "${start}" \
  --tail-hours "${sample_tail_hours}" \
  --count "${sample_noise_count}" \
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

# Bead sample
echo "$(date -u): Subsampling for beads" 1>&2
timeout -k 60s 600s seaflowpy evt sample \
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

# OPP sample
echo "$(date -u): Subsampling OPP" 1>&2
timeout -k 60s 600s python3 /local/sample.py \
  --count "${opp_sample_count}" \
  "/jobs_data/seaflow-analysis/${cruise}/${instrument}/${cruise}_opp" \
  "${outdir}"
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
        memory = 200
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

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

# Copy for sync to shore
echo "$(date): copying ${outdir} to minio:sync/subsample/${cruise}/${instrument}/${timestamp}" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
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
