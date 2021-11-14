variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "par" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/15 * * * *"  // every 15 minutes
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "par" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "parse" {
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
        memory = 500
        cpu = 300
      }

      template {
        data = <<EOH
PAR_PROJECT="{{ key "cruise/name" }}"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
#!/bin/bash

cruise="{{ key "cruise/name" }}"

[[ -d "/jobs_data/par/${cruise}" ]] || mkdir -p "/jobs_data/par/${cruise}"
python3 /local/parse.py /jobs_data/par_data > "/jobs_data/par/${cruise}"/par_${cruise}.tsdata
        EOH
        destination = "local/run.sh"
        perms = "755"
      }

      template {
        data = <<EOH
#!/usr/bin/env python3
# Parse Gradients 4 PAR logs
#
# Assume UTC for all PAR timestamps

import datetime
import glob
import logging
import re
import sys


import click
import pandas as pd

logging.basicConfig(format='%(asctime)s: %(message)s', level=logging.INFO, datefmt="%Y-%m-%dT%H:%M:%S%z")

time_re = re.compile(r"^\[(\d\d)/(\d\d)/(\d\d) - (\d\d):(\d\d):(\d\d):(\d\d\d)\]$")
par_re = re.compile(r"^\$PPAR,(.+)$")

@click.command()
@click.option("--project", default="par-project", type=str, help="Project name")
@click.argument("indir", type=click.Path(exists=True, dir_okay=True, file_okay=False, readable=True))
def cli(project, indir):
    logging.info("starting project=%s indir=%s", project, indir)
    df = pd.DataFrame()
    for path in sorted(glob.glob(f"{indir}/ParLog_*")):
        logging.info("reading %s", path)
        # resample from 1 second frequency to 1 minute
        try:
            subdf = pd.DataFrame(read_par(path)).set_index("time").sort_index().resample("T").median()
        except (IOError, OSError) as e:
            logging.warning("could not read %s: %s", path, e)
        df = pd.concat([df, subdf])
    print("par")
    print(project)
    print("Thompson PAR data")
    print("\t".join(["RFC3339 timestamp", "PAR"]))
    print("\t".join(["time", "float"]))
    print("\t".join(["NA", "NA"]))
    if not df.empty:
        df = df.sort_index().resample("T").median()
        df.to_csv(sys.stdout, sep="\t", na_rep="NA", float_format="%.03f", date_format="%Y-%m-%dT%H:%M:%S+00:00")
    logging.info("done")


def read_par(path):
    with open(path, encoding="utf8", errors="ignore") as fh:
        t = None
        times, pars = [], []

        for linenum, line in enumerate(fh):
            line = line.rstrip()

            if line.startswith("["):
                time_match = time_re.match(line)
                if time_match:
                    day, month, year, hour, minute, second, microsecond = time_match.groups()
                    stamp = f"20{year}-{month}-{day}T{hour}:{minute}:{second}.{microsecond}+00:00"
                    try:
                        t = datetime.datetime.fromisoformat(stamp)
                    except ValueError as e:
                        logging.warning("bad timestamp %s on line number %d", line, linenum + 1)
                        t = None
            elif (t is not None) and line.startswith("$PPAR,"):
                _, par, _ = line.split(",", 2)
                par = par.strip()
                try:
                    times.append(t), pars.append(float(par))
                except ValueError as e:
                    logging.warning("bad float %s on line number %d", par, linenum + 1)
                    val = None
                t = None  # reset time
        return { "time": times, "par": pars }


if __name__ == "__main__":
    cli(auto_envvar_prefix='PAR')

        EOH
        destination = "local/parse.py"
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
        destination = "/secrets/rclone.config"
        change_mode = "restart"
        perms = "644"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

cruise="{{ key "cruise/name" }}"

# Copy for dashboard data
echo "$(date): copying /jobs_data/par/${cruise}/par_${cruise}.tsdata to minio:data/par/${cruise}/par_${cruise}.tsdata" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/par/${cruise}/par_${cruise}.tsdata" \
  minio:data/par/${cruise}/par_${cruise}.tsdata

# Copy for sync to shore
echo "$(date): copying /jobs_data/par/${cruise}/par_${cruise}.tsdata to minio:sync/par/par_${cruise}.tsdata" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
  "/jobs_data/par/${cruise}/par_${cruise}.tsdata" \
  minio:sync/par/${cruise}/par_${cruise}.tsdata

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }
    }
  }
}
