#!/usr/bin/env Rscript

# optparse may not be installed globally so look for renv directory before
# parsing cli args with optparse
args <- commandArgs(trailingOnly = TRUE)
renv_loc <- args == "--renv"
if (any(renv_loc)) {
  renv_idx <- which(renv_loc)
  if (length(args) > renv_idx) {
    proj_dir <- renv::activate(args[renv_idx + 1])
    message("activated renv directory ", proj_dir)
  }
}

library(tidyverse)

parser <- optparse::OptionParser(usage = "usage: realtime-popcycle.R --db FILE --vct-dir FILE --opp-dir DIR [options]")
# Have a separate instrument option here because in some cases the serial and
# instrument name may differ. The serial will be used in the database to look up
# values in the Mie theory table. If a new instrument (v2) has no entries in this
# table the lookup will fail. To "fix" this, use instrument name to name output
# files etc, and use a valid db serial (e.g. 740) for internal popcycle anlysis.
parser <- optparse::add_option(parser, c("--instrument"),
  type = "character", default = "",
  help = "Instrument name (may differ from db serial). Required.",
  metavar = "NAME"
)
parser <- optparse::add_option(parser, c("--db"),
  type = "character", default = "",
  help = "Popcycle database file. Required.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--evt-dir"),
  type = "character", default = "",
  help = "EVT directory. Required.",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, c("--opp-dir"),
  type = "character", default = "",
  help = "OPP directory. Required.",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, c("--vct-dir"),
  type = "character", default = "",
  help = "VCT directory. Required.",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, c("--stats-abund-file"),
  type = "character", default = "",
  help = "Stats table output file with abundance.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--stats-no-abund-file"),
  type = "character", default = "",
  help = "Stats table output file without abundance.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--sfl-file"),
  type = "character", default = "",
  help = "SFL table output file.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--correction"),
  type = "double", default = 1,
  help = "Abundance correction factor.",
  metavar = "NUMBER"
)
parser <- optparse::add_option(parser, c("--volume"),
  type = "double", default = -1,
  help = "Use a constant volume value instead of calculating from SFL.",
  metavar = "NUMBER"
)
parser <- optparse::add_option(parser, c("--cores"),
  type = "integer", default = 1,
  help = "Number of cores to use.",
  metavar = "NUMBER"
)
parser <- optparse::add_option(parser, "--renv",
  type = "character", default = "", metavar = "dir",
  help = "Optional renv directory to use. Requires the renv package."
)

p <- optparse::parse_args2(parser)
if (p$options$instrument == "" || p$options$db == "" || p$options$evt_dir == "" || p$options$opp_dir == "" || p$options$vct_dir == "") {
  # Do nothing if instrument, db, evt_dir, opp_dir, vct_dir are not specified
  message("error: must specify all of --instrument, --db, --evt-dir, --opp-dir, --vct-dir")
  optparse::print_help(parser)
  quit(save = "no", status = 10)
} else {
  cores <- p$options$cores
  inst <- p$options$instrument
  db <- p$options$db
  evt_dir <- p$options$evt_dir
  opp_dir <- p$options$opp_dir
  vct_dir <- p$options$vct_dir

  if (!file.exists(db)) {
    message(paste0("db does not exist"))
    quit(save = FALSE, status = 11)
  }
}

stats_no_abund_file <- p$options$stats_no_abund_file
stats_abund_file <- p$options$stats_abund_file
sfl_file <- p$options$sfl_file
correction <- p$options$correction
volume <- p$options$volume
if ((!is.numeric(volume)) || (volume < 0)) {
  volume <- NULL
}

serial <- popcycle::get_inst(db)
cruise <- popcycle::get_cruise(db)
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
message(paste0("evt-dir = ", evt_dir))
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
meta <- popcycle::create_realtime_meta(db, quantile_, volume = volume)
dated_msg("Created SFL table")
# OPP EVT ratio
opp_evt_ratio <- meta %>%
  filter(opp_count > 0) %>%
  pull(opp_evt_ratio) %>%
  median()
volume_virtualcore <- opp_evt_ratio * volume
dated_msg(paste0("median(opp_evt_ratio) where opp_count > 0 = ", opp_evt_ratio))
dated_msg(paste0("virtualcore volume = ", volume_virtualcore))
# Create population statistics table
dated_msg("Creating pop table")
pop <- popcycle::create_realtime_bio(db, quantile_, correction = correction, volume = volume_virtualcore) %>%
  dplyr::select(date, pop, n_count, abundance, diam_mid, diam_lwr, correction)

if (sfl_file != "") {
  dated_msg("saving SFL / metadata file")
  filetype <- paste0("SeaFlowSFL_", inst)
  description <- paste0("SeaFlow SFL data for instrument ", inst)
  popcycle::write_realtime_meta_tsdata(
    meta, sfl_file,
    project = cruise, filetype = filetype, description = description
  )
  dated_msg("saved SFL / metadata file")
}

if (stats_abund_file != "") {
  dated_msg("saving stats / bio file with abundance")
  filetype <- paste0("SeaFlowPopAbundance_", inst)
  description <- paste0("SeaFlow population data for instrument ", inst)
  popcycle::write_realtime_bio_tsdata(
    pop, stats_abund_file,
    project = cruise, filetype = filetype, description = description
  )
  dated_msg("saved stats / bio file with abundance")
}

if (stats_no_abund_file != "") {
  dated_msg("saving stats / bio file without abundance")
  filetype <- paste0("SeaFlowPop_", inst)
  description <- paste0("SeaFlow population data without abundance for instrument ", inst)
  popcycle::write_realtime_bio_tsdata(
    pop %>% dplyr::select(-c(abundance)), stats_no_abund_file,
    project = cruise, filetype = filetype, description = description
  )
  dated_msg("saved stats / bio file without abundance")
}

dated_msg("Done")
