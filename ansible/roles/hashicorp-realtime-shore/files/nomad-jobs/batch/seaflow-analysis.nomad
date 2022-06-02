variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "seaflow-analysis" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "5,20,35,50 * * * *"  // at 5,20,35,50 min every hour
    prohibit_overlap = true
    time_zone = "UTC"
  }

  parameterized {
    meta_required = ["instrument"]
  }

  # No restart attempts
  reschedule {
    attempts = 1
    unlimited = false
  }

  group "seaflow-analysis" {
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
        memory = 50
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

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

# First extract the base db, which is base64 encoded gzipped content
# Work backward from this
# gzip -c base.db | base64 | consul kv put "seaflow-analysis/${instrument}/dbgz" -
consul kv get "seaflow-analysis/${NOMAD_META_instrument}/dbgz" | \
  base64 --decode | \
  gzip -dc > ${NOMAD_ALLOC_DIR}/data/base.db
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "filter" {
      driver = "docker"

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image = "ctberthiaume/seaflowpy:local"
        command = "/local/run.sh"
      }

      resources {
        memory = 5000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Perform SeaFlow setup and filtering

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

echo "seaflowpy version = $(seaflowpy version)"

outdir="/jobs_data/seaflow-analysis/${cruise}/${instrument}"
rawdatadir="/jobs_data/seaflow-transfer/${cruise}/${instrument}/evt"
dbfile="${outdir}/${cruise}.db"

echo "cruise=${cruise}"
echo "instrument=${instrument}"
echo "outdir=${outdir}"
echo "rawdatadir=${rawdatadir}"
echo "serial=${serial}"
echo "dbfile=${dbfile}"

# Create output directory if it doesn't exist
if [[ ! -d "${outdir}" ]]; then
  echo "Creating output directory ${outdir}"
  mkdir -p "${outdir}" || exit $?
fi

# Create an new empty database if one doesn't exist
if [ ! -e "$dbfile" ]; then
  echo "Creating $dbfile with cruise=$cruise and inst=$serial"
  seaflowpy db create -c "$cruise" -s "$serial" -d "$dbfile" || exit $?
fi

# Overwrite any existing filter and gating params with the base db pulled from
# consul
echo "Overwriting filter, gating, poly tables in ${dbfile} with data from consul"
sqlite3 "${dbfile}" 'drop table filter' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump filter" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table gating' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump gating" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table poly' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump poly" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table gating_plan' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump gating_plan" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table filter_plan' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump filter_plan" | sqlite3 "${dbfile}" || exit $?

# Find and import all SFL files in rawdatadir
echo "Importing SFL data in $rawdatadir"
echo "Saving cleaned and concatenated SFL file at ${outdir}/${cruise}.sfl"
# Just going to assume there are no newlines in filenames here (there shouldn't be!)
seaflowpy sfl print $(/usr/bin/find "$rawdatadir" -name '*.sfl' | sort) > "${outdir}/${cruise}.concatenated.sfl" || exit $?
seaflowpy db import-sfl -f "${outdir}/${cruise}.concatenated.sfl" "$dbfile" || exit $?

# Filter new files with seaflowpy
echo "Filtering data in ${rawdatadir} and writing to ${outdir}"
seaflowpy filter -p 2 --delta -e "$rawdatadir" -d "$dbfile" -o "$outdir/${cruise}_opp" || exit $?
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "classification" {
      driver = "docker"

      config {
        image = "ctberthiaume/popcycle:local"
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
        memory = 8000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env Rscript
library(tidyverse)

parser <- optparse::OptionParser(usage="usage: realtime-classify.R --db FILE --vct-dir FILE --opp-dir DIR [options]")
# Have a separate instrument option here because in some cases the serial and
# instrument name may differ. The serial will be used in the database to look up
# values in the Mie theory table. If a new instrument (v2) has no entries in this
# table the lookup will fail. To "fix" this, use instrument name to name output
# files etc, and use a valid db serial (e.g. 740) for internal popcycle anlysis.
parser <- optparse::add_option(parser, c("--instrument"), type="character", default="",
                               help="Instrument name (may differ from db serial). Required.",
                               metavar="NAME")
parser <- optparse::add_option(parser, c("--db"), type="character", default="",
                               help="Popcycle database file. Required.",
                               metavar="FILE")
parser <- optparse::add_option(parser, c("--opp-dir"), type="character", default="",
                               help="OPP directory. Required.",
                               metavar="DIR")
parser <- optparse::add_option(parser, c("--vct-dir"), type="character", default="",
                               help="VCT directory. Required.",
                               metavar="DIR")
parser <- optparse::add_option(parser, c("--stats-abund-file"), type="character", default="",
                               help="Stats table output file with abundance.",
                               metavar="FILE")
parser <- optparse::add_option(parser, c("--stats-no-abund-file"), type="character", default="",
                               help="Stats table output file without abundance.",
                               metavar="FILE")
parser <- optparse::add_option(parser, c("--sfl-file"), type="character", default="",
                               help="SFL table output file.",
                               metavar="FILE")
parser <- optparse::add_option(parser, c("--correction"), type="double", default=1,
                               help="Abundance correction factor.",
                               metavar="NUMBER")
parser <- optparse::add_option(parser, c("--volume"), type="double", default=-1,
                               help="Use a constant volume value instead of calculating from SFL.",
                               metavar="NUMBER")
parser <- optparse::add_option(parser, c("--cores"), type="integer", default=1,
                               help="Number of cores to use.",
                               metavar="NUMBER")

p <- optparse::parse_args2(parser)
if (p$options$instrument == "" || p$options$db == "" || p$options$opp_dir == "" || p$options$vct_dir == "") {
  # Do nothing if instrument, db, opp_dir, vct_dir are not specified
  message("error: must specify all of --instrument, --db, --opp-dir, --vct-dir")
  optparse::print_help(parser)
  quit(save="no", status=10)
} else {
  cores <- p$options$cores
  inst <- p$options$instrument
  db <- p$options$db
  opp_dir <- p$options$opp_dir
  vct_dir <- p$options$vct_dir

  if (!dir.exists(opp_dir) || !file.exists(db)) {
    message(paste0("opp_dir or db does not exist"))
    quit(save=FALSE, status=11)
  }
}

stats_no_abund_file <- p$options$stats_no_abund_file
stats_abund_file <- p$options$stats_abund_file
sfl_file <- p$options$sfl_file
correction <- p$options$correction
volume <- p$options$volume
if ((! is.numeric(volume)) || (volume < 0)) {
  volume <- NULL
}

serial <- popcycle::get_inst(db)
cruise <-popcycle::get_cruise(db)
quantile_ <- "2.5"

dated_msg <- function(...) {
  message(format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"), ": ", ...)
}

dated_msg("Start")
message("Configuration:")
message("--------------")
message(paste0("db = ", db))
message(paste0("cruise (from db) = ", cruise))
message(paste0("serial (from db) = ", serial))
message(paste0("instrument = ", inst))
message(paste0("opp-dir = ", opp_dir))
message(paste0("vct-dir = ", vct_dir))
message(paste0("stats-no-abund-file = ", stats_no_abund_file))
message(paste0("stats-abund-file = ", stats_abund_file))
message(paste0("sfl-file = ", sfl_file))
message(paste0("quantile = ", quantile_))
message(paste0("correction = ", correction))
message(paste0("volume = ", volume))
message("--------------")

############################
### ANALYZE NEW FILE(s) ###
############################
dated_msg("Starting filtering")
popcycle::filter_evt_files(db, evt_dir, NULL, opp_dir, cores = cores)
dated_msg("Completed filtering")
dated_msg("Starting gating")
popcycle::classify_opp_files(db, opp_dir, NULL, vct_dir, cores = cores)
dated_msg("Completed gating")

##########################
### Save Stats and SFL ###
##########################
# Create SFL table
dated_msg("Creating SFL table")
meta <- popcycle::create_realtime_meta(db, quantile_, volume=volume)
dated_msg("Created SFL table")
# Create population statistics table with no abundance
dated_msg("Creating pop table with no abundance")
stats_no_abund <- popcycle::create_realtime_bio(db, quantile_, correction=correction, with_abundance=FALSE)
dated_msg("Created pop table with no abundance")

# Add abundance
dated_msg("Creating pop table with abundance")
pop <- popcycle::create_realtime_bio(db, quantile_, correction=correction, with_abundance=FALSE)
volumes <- popcycle::create_volume_table(meta, time_expr=NULL)
pop <- dplyr::left_join(pop, volumes, by="date")
pop_idx <- (pop$pop == "prochloro") | (pop$pop == "synecho")
pop[, "abundance"] <- pop[, "n_count"] / pop[, "volume_large"]
pop[pop_idx, "abundance"] <- pop[pop_idx, "n_count"] / pop[pop_idx, "volume_small"]
pop <- pop %>%
  dplyr::select(date, pop, n_count, abundance, diam_mid, diam_lwr, correction)
dated_msg("Created pop table with abundance")

if (sfl_file != "") {
  dated_msg("saving SFL / metadata file")
  filetype <- paste0("SeaFlowSFL_", inst)
  description <- paste0("SeaFlow SFL data for instrument ", inst)
  popcycle::write_realtime_meta_tsdata(
    meta, sfl_file, project=cruise, filetype=filetype, description=description
  )
  dated_msg("saved SFL / metadata file")
}

if (stats_abund_file != "") {
  dated_msg("saving stats / bio file with abundance")
  filetype <- paste0("SeaFlowPopAbundance_", inst)
  description <- paste0("SeaFlow population data for instrument ", inst)
  popcycle::write_realtime_bio_tsdata(
    pop, stats_abund_file, project=cruise, filetype=filetype, description=description
  )
  dated_msg("saved stats / bio file with abundance")
}

if (stats_no_abund_file != "") {
  dated_msg("saving stats / bio file without abundance")
  filetype <- paste0("SeaFlowPop_", inst)
  description <- paste0("SeaFlow population data without abundance for instrument ", inst)
  popcycle::write_realtime_bio_tsdata(
    stats_no_abund, stats_no_abund_file, project=cruise, filetype=filetype, description=description
  )
  dated_msg("saved stats / bio file without abundance")
}

dated_msg("Done")

        EOH
        destination = "/local/cron_job.R"
        change_mode = "restart"
        perms = "755"
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
oppdir="${outdir}/${cruise}_opp"
vctdir="${outdir}/${cruise}_vct"
statsabundfile="${outdir}/stats-abund.${cruise}.${instrument}.tsdata"
statsnoabundfile="${outdir}/stats-no-abund.${cruise}.${instrument}.tsdata"
sflfile="${outdir}/sfl.popcycle.${cruise}.${instrument}.tsdata"

Rscript --slave -e 'message(packageVersion("popcycle"))'

# Classify and produce summary image files
echo "$(date -u): Classifying data in ${outdir}" >&2
timeout -k 60s 2h \
Rscript --slave /local/cron_job.R \
  --instrument "${instrument}" \
  --db "${dbfile}" \
  --opp-dir "${oppdir}" \
  --vct-dir "${vctdir}" \
  --stats-abund-file "${statsabundfile}" \
  --stats-no-abund-file "${statsnoabundfile}" \
  --sfl-file "${sflfile}" \
  --correction "${correction}" \
  --volume "${volume}"
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
