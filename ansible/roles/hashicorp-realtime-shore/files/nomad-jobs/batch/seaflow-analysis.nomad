variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "seaflow-analysis" {
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

  group "seaflow-analysis" {
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

# Can't use normal nomad template with consul key here because we need to
# use the env var NOMAD_META_instrument to construct the correct consul key
# for this particular instrument. This is set by nomad at run time, not at job
# registration time, so we have to use `consul kv get`.

set -e

# Get cruise name
echo "cruise=$(consul kv get cruise/name)" > ${NOMAD_ALLOC_DIR}/data/vars
# Get instrument name
echo "instrument=${NOMAD_META_instrument}" >> ${NOMAD_ALLOC_DIR}/data/vars
# Get instrument serial
echo "serial=$(consul kv get seaflowconfig/${NOMAD_META_instrument}/serial)" >> ${NOMAD_ALLOC_DIR}/data/vars
# Get abundance correction
echo "correction=$(consul kv get seaflow-analysis/${NOMAD_META_instrument}/abundance-correction)" >> ${NOMAD_ALLOC_DIR}/data/vars
# Get volume constant
echo "volume=$(consul kv get seaflow-analysis/${NOMAD_META_instrument}/volume-constant)" >> ${NOMAD_ALLOC_DIR}/data/vars
# Get realtime DB repo URL
echo "repodburl=$(consul kv get seaflow-analysis/${NOMAD_META_instrument}/db-repo-url)" >> ${NOMAD_ALLOC_DIR}/data/vars
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "prep-db" {
      driver = "docker"

      config {
        image = "ctberthiaume/seaflowpy:local"
        command = "/local/run.sh"

        mount {
          type = "bind"
          target = "/jobs_data"
          source = "/jobs_data"
          volume_options {
            no_copy = true
          }
        }
      }

      resources {
        memory = 200
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Perform SeaFlow setup

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

echo "seaflowpy version = $(seaflowpy version)"

outdir="/jobs_data/seaflow-analysis/${cruise}/${instrument}"
rawdatadir="/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"
repodir="${outdir}/realtime-dbs"
repodbfile="${repodir}/dbs/${cruise}_${instrument}.db"
dbfile="${outdir}/${cruise}.db"

echo "cruise=${cruise}"
echo "instrument=${instrument}"
echo "outdir=${outdir}"
echo "rawdatadir=${rawdatadir}"
echo "repodir=${repodir}"
echo "repodburl=${repodburl}"
echo "serial=${serial}"
echo "dbfile=${dbfile}"
echo "repodbfile=${repodbfile}"

# Create output directory if it doesn't exist
if [[ ! -d "${outdir}" ]]; then
  echo "Creating output directory ${outdir}"
  mkdir -p "${outdir}" || exit $?
fi

# Clone and pull the db repo
if [[ ! -d "${repodir}" ]]; then
  git clone "${repodburl}" "${repodir}"
fi
(cd "${repodir}" && git pull)

# Check for git parameters db file
if [[ ! -e "${repodbfile}" ]]; then
  echo "could not find git repo db parameters file: ${repodbfile}"
  exit 1
fi

# Create an new empty database if one doesn't exist
if [ ! -e "$dbfile" ]; then
  echo "Creating $dbfile with cruise=$cruise and inst=$serial"
  seaflowpy db create -c "$cruise" -s "$serial" -d "$dbfile" || exit $?
fi

echo "Overwriting filter, gating, poly tables in ${dbfile} with data from git repo"
sqlite3 "${dbfile}" 'drop table filter' || exit $?
sqlite3 "${repodbfile}" ".dump filter" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table gating' || exit $?
sqlite3 "${repodbfile}" ".dump gating" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table poly' || exit $?
sqlite3 "${repodbfile}" ".dump poly" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table gating_plan' || exit $?
sqlite3 "${repodbfile}" ".dump gating_plan" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table filter_plan' || exit $?
sqlite3 "${repodbfile}" ".dump filter_plan" | sqlite3 "${dbfile}" || exit $?

# Find and import all SFL files in rawdatadir
echo "Importing SFL data in $rawdatadir"
echo "Saving cleaned and concatenated SFL file at ${outdir}/${cruise}.sfl"
# Just going to assume there are no newlines in filenames here (there shouldn't be!)
seaflowpy sfl print $(/usr/bin/find "$rawdatadir" -name '*.sfl' | sort) > "${outdir}/${cruise}.concatenated.sfl" || exit $?
seaflowpy db import-sfl -f "${outdir}/${cruise}.concatenated.sfl" "$dbfile" || exit $?
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "main" {
      driver = "docker"

      config {
        image = "ctberthiaume/popcycle:local"
        command = "/local/run.sh"
        
        mount {
          type = "bind"
          target = "/jobs_data"
          source = "/jobs_data"
          volume_options {
            no_copy = true
          }
        }

        mount {
          type = "bind"
          target = "/scripts"
          source = "/etc/realtime/scripts"
          readonly = true
          volume_options {
            no_copy = true
          }
        }
      }

      lifecycle {
        hook = "poststop"
        sidecar = false
      }

      resources {
        memory = 10000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Perform SeaFlow classification

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

outdir="/jobs_data/seaflow-analysis/${cruise}/${instrument}"
dbfile="${outdir}/${cruise}.db"
evtdir="/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"
oppdir="${outdir}/${cruise}_opp"
vctdir="${outdir}/${cruise}_vct"
statsabundfile="${outdir}/stats-abund.${cruise}.${instrument}.tsdata"
statsnoabundfile="${outdir}/stats-no-abund.${cruise}.${instrument}.tsdata"
sflfile="${outdir}/sfl.popcycle.${cruise}.${instrument}.tsdata"

Rscript --slave -e 'message(packageVersion("popcycle"))'

# Classify and produce summary image files
echo "$(date -u): Classifying data in ${outdir}" >&2
timeout -k 60s 2h \
Rscript --slave /scripts/realtime-popcycle.R \
  --instrument "${instrument}" \
  --db "${dbfile}" \
  --evt-dir "${evtdir}" \
  --opp-dir "${oppdir}" \
  --vct-dir "${vctdir}" \
  --stats-abund-file "${statsabundfile}" \
  --stats-no-abund-file "${statsnoabundfile}" \
  --sfl-file "${sflfile}" \
  --correction "${correction}" \
  --volume "${volume}" \
  --cores 2
status=$?
if [[ ${status} -eq 124 ]]; then
  echo "$(date -u): classification killed by timeout sigint" 1>&2
elif [[ ${status} -eq 137 ]]; then
  echo "$(date -u): classification killed by timeout sigkill" 1>&2
elif [[ ${status} -gt 0 ]]; then
  echo "$(date -u): classification exited with an error, status = ${status}" 1>&2
else
  echo "$(date -u): classification completed successfully" 1>&2
fi

# Export section
# -----------------------------------------------------------------------------
# Would put this in a separate task to run after this and upload to minio
# directly but we've already used all task lifecycle types available and rclone
# is not in the popcycle docker image.

# Copy for dashboard data
echo "$(date -u): Copying data for dashboard ingest" >&2
[[ ! -d "/jobs_data/ingestwatch/seaflow-analysis/${cruise}" ]] && mkdir -p "/jobs_data/ingestwatch/seaflow-analysis/${cruise}"
cp -a "${statsabundfile}" "/jobs_data/ingestwatch/seaflow-analysis/${cruise}/"
cp -a "${sflfile}" "/jobs_data/ingestwatch/seaflow-analysis/${cruise}/"
echo "$(date -u): Completed dashboard ingest copy" >&2

# # Copy for sync to shore
echo "$(date -u): Copying data for sync" >&2
[[ ! -d "/jobs_data/sync/seaflow-analysis/${cruise}" ]] && mkdir -p "/jobs_data/sync/seaflow-analysis/${cruise}"
cp -a "${statsnoabundfile}" /jobs_data/sync/seaflow-analysis/${cruise}/
cp -a "${sflfile}" /jobs_data/sync/seaflow-analysis/${cruise}/
echo "$(date -u): Completed sync copy" >&2
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }
  }
}
