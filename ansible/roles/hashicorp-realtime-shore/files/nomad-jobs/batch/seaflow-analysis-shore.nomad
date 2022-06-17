variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "seaflow-analysis-shore" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/10 * * * *"
    prohibit_overlap = true
    time_zone = "UTC"
  }

  parameterized {
    meta_required = [
      "cruise",
      "instrument"
    ]
  }

  # No restart attempts
  reschedule {
    attempts = 1
    unlimited = false
  }

  group "seaflow-analysis-shore" {
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
echo "correction=$(consul kv get seaflow-analysis-shore/${NOMAD_META_instrument}/abundance-correction)" >> ${NOMAD_ALLOC_DIR}/data/vars
# Get volume constant
echo "volume=$(consul kv get seaflow-analysis-shore/${NOMAD_META_instrument}/volume-constant)" >> ${NOMAD_ALLOC_DIR}/data/vars
# Realtime sync directory
echo "syncdir=/jobs_data/realtime-sync"
# Output directory
echo "outdir=/jobs_data/seaflow-analysis-shore/${cruise}/${instrument}"

# First extract the base db, which is base64 encoded gzipped content
# Work backward from this
# gzip -c base.db | base64 | consul kv put "seaflow-analysis-shore/${instrument}/dbgz" -
consul kv get "seaflow-analysis-shore/${NOMAD_META_instrument}/dbgz" | \
  base64 --decode | \
  gzip -dc > ${NOMAD_ALLOC_DIR}/data/base.db
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }

    task "classification" {
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
CREATE VIEW IF NOT EXISTS stat AS
  SELECT
    opp.file as file,
    sfl.date as time,
    sfl.lat as lat,
    sfl.lon as lon,
    sfl.ocean_tmp as temp,
    sfl.salinity as salinity,
    sfl.par as par,
    vct.quantile as quantile,
    vct.pop as pop,
    sfl.stream_pressure as stream_pressure,
    sfl.file_duration as file_duration,
    sfl.event_rate as event_rate,
    opp.opp_evt_ratio as opp_evt_ratio,
    vct.count as n_count,
    vct.chl_1q as chl_1q,
    vct.chl_med as chl_med,
    vct.chl_3q as chl_3q,
    vct.pe_1q as pe_1q,
    vct.pe_med as pe_med,
    vct.pe_3q as pe_3q,
    vct.fsc_1q as fsc_1q,
    vct.fsc_med as fsc_med,
    vct.fsc_3q as fsc_3q,
    vct.diam_lwr_1q as diam_lwr_1q,
    vct.diam_lwr_med as diam_lwr_med,
    vct.diam_lwr_3q as diam_lwr_3q,
    vct.diam_mid_1q as diam_mid_1q,
    vct.diam_mid_med as diam_mid_med,
    vct.diam_mid_3q as diam_mid_3q,
    vct.diam_upr_1q as diam_upr_1q,
    vct.diam_upr_med as diam_upr_med,
    vct.diam_upr_3q as diam_upr_3q,
    vct.Qc_lwr_1q as Qc_lwr_1q,
    vct.Qc_lwr_med as Qc_lwr_med,
    vct.Qc_lwr_mean as Qc_lwr_mean,
    vct.Qc_lwr_3q as Qc_lwr_3q,
    vct.Qc_mid_1q as Qc_mid_1q,
    vct.Qc_mid_med as Qc_mid_med,
    vct.Qc_mid_mean as Qc_mid_mean,
    vct.Qc_mid_3q as Qc_mid_3q,
    vct.Qc_upr_1q as Qc_upr_1q,
    vct.Qc_upr_med as Qc_upr_med,
    vct.Qc_upr_mean as Qc_upr_mean,
    vct.Qc_upr_3q as Qc_upr_3q
  FROM
    opp, vct, sfl
  WHERE
    opp.quantile == vct.quantile
    AND
    opp.file == vct.file
    AND
    opp.file == sfl.file
  ORDER BY
    time, pop ASC;

        EOH
        destination = "/local/stat.sql"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Perform SeaFlow setup and classification

set -e

# Get variables defined by setup task
source ${NOMAD_ALLOC_DIR}/data/vars

echo "seaflowpy version = $(seaflowpy version)"

dbfile="${outdir}/${cruise}.db"

echo "cruise=${cruise}"
echo "instrument=${instrument}"
echo "outdir=${outdir}"
echo "syncdir=${syncdir}"
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

# Fix stat table to not care if there are more than one filter params defined
sqlite3 "$dbfile" 'drop view stat'
sqlite3 "$dbfile" < /local/stat.sql

# Overwrite any existing filter and gating params with the base db pulled from
# consul
echo "Overwriting filter, gating, poly tables in ${dbfile} with data from consul"
sqlite3 "${dbfile}" 'drop table filter' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump filter" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table gating' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump gating" | sqlite3 "${dbfile}" || exit $?
sqlite3 "${dbfile}" 'drop table poly' || exit $?
sqlite3 ${NOMAD_ALLOC_DIR}/data/base.db ".dump poly" | sqlite3 "${dbfile}" || exit $?

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

p <- optparse::parse_args2(parser)
if (p$options$instrument == "" || p$options$db == "" || p$options$opp_dir == "" || p$options$vct_dir == "") {
  # Do nothing if instrument, db, opp_dir, vct_dir are not specified
  message("error: must specify all of --instrument, --db, --opp-dir, --vct-dir")
  optparse::print_help(parser)
  quit(save="no", status=10)
} else {
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

serial <- popcycle::get.inst(db)
cruise <-popcycle::get.cruise(db)
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
opp_list <- popcycle::get.opp.files(db, all.files=FALSE)
vct_list <- unique(popcycle::get.vct.table(db)$file)
files_to_gate <- setdiff(opp_list, vct_list)
dated_msg(paste0("gating ", length(files_to_gate), " files"))
if (length(files_to_gate) > 0) {
  popcycle::classify.opp.files(db, opp_dir, files_to_gate, vct_dir)
}
dated_msg("Completed gating")

##########################
### Save Stats and SFL ###
##########################
# Create SFL table
dated_msg("Creating SFL table")
meta <- create_realtime_meta(db, quantile_, volume=volume)
dated_msg("Created SFL table")
# Create population statistics table with no abundance
dated_msg("Creating pop table with no abundance")
stats_no_abund <- create_realtime_bio(db, quantile_, correction_=correction, with_abundance=FALSE)
dated_msg("Created pop table with no abundance")

# Add abundance
dated_msg("Creating pop table with abundance")
pop <- create_realtime_bio(db, quantile_, correction_=correction, with_abundance=FALSE)
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
  write_realtime_bio_tsdata(
    pop, stats_abund_file, project=cruise, filetype=filetype, description=description
  )
  dated_msg("saved stats / bio file with abundance")
}

if (stats_no_abund_file != "") {
  dated_msg("saving stats / bio file without abundance")
  filetype <- paste0("SeaFlowPop_", inst)
  description <- paste0("SeaFlow population data without abundance for instrument ", inst)
  write_realtime_bio_tsdata(
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

Rscript --slave -e 'message(packageVersion("popcycle"))'

# Classify and produce summary files
echo "$(date -u): Classifying data in ${outdir}" >&2
timeout -k 60s 2h \
Rscript --slave /local/cron_job.R \
  --instrument "${instrument}" \
  --sync-dir "${syncdir}" \
  --out-dir "${outdir}" \
  --correction "${correction}" \
  --volume "${volume}" >&2

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
[[ ! -d "/jobs_data/ingestwatch/seaflow-analysis-shore/${cruise}" ]] && mkdir -p "/jobs_data/ingestwatch/seaflow-analysis-shore/${cruise}"

find "${outdir}" -type f -name '*.tsdata' >&2
find "${outdir}" -type f -name '*.tsdata' -exec \
  cp -a "{}" "/jobs_data/ingestwatch/seaflow-analysis-shore/${cruise}/" \;
echo "$(date -u): Completed dashboard ingest copy" >&2

        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }
  }
}
