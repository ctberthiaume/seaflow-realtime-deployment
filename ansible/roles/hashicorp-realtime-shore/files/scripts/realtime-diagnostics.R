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

#' Create a temporary file name
mktempname <- function(root_dir, suffix) {
  rand8char <- stringr::str_sub(uuid::UUIDgenerate(), 1, 8)
  timestamp <- lubridate::format_ISO8601(lubridate::now())
  return(file.path(root_dir, glue::glue("._{rand8char}_{timestamp}_{suffix}")))
}

parser <- optparse::OptionParser(usage = "usage: realtime-diagnostics.R [options] ")
parser <- optparse::add_option(parser, c("--cruise"),
  type = "character", default = "",
  help = "Cruise name. Required.",
  metavar = "NAME"
)
parser <- optparse::add_option(parser, c("--instrument"),
  type = "character", default = "",
  help = "Instrument name. Required.",
  metavar = "NAME"
)
parser <- optparse::add_option(parser, c("--subsample-dir"),
  type = "character", default = "",
  help = "Bead subsample directory. Required",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, c("--stats-file"),
  type = "character", default = "",
  help = "SeaFlow realtime stats file with 'time', 'pop', 'n_counts'. Required.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--drift-file"),
  type = "character", default = "",
  help = "Output file for bead drift away from reference positions. Required.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, c("--background-file"),
  type = "character", default = "",
  help = "Output file for background particle percentage. Required.",
  metavar = "FILE"
)
parser <- optparse::add_option(parser, "--renv",
  type = "character", default = "", metavar = "dir",
  help = "Optional renv directory to use. Requires the renv package."
)

p <- optparse::parse_args2(parser)
if (p$options$cruise == "" || p$options$instrument == "" || p$options$subsample_dir == "" || p$options$stats_file == "" || p$options$drift_file == "" || p$options$background_file == "") {
  # Exit with error if required args aren't specified
  message("error: must specify all of --cruise, --instrument, --subsample-dir, --stats-file, --drift-file, --background-file")
  optparse::print_help(parser)
  quit(save = "no", status = 10)
} else {
  cruise <- p$options$cruise
  inst <- p$options$instrument
  subsample_dir <- p$options$subsample_dir
  stats_file <- p$options$stats_file
  drift_file <- p$options$drift_file
  background_file <- p$options$background_file
}

dated_msg <- function(...) {
  message(format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"), ": ", ...)
}

dated_msg("Start")
message("Configuration:")
message("--------------")
message(paste0("cruise = ", cruise))
message(paste0("instrument = ", inst))
message(paste0("subsample-dir = ", subsample_dir))
message(paste0("stats-file = ", stats_file))
message(paste0("drift-file = ", drift_file))
message(paste0("background-file = ", background_file))

ref <- tryCatch(
  popcycle::read_reference_filter_params(inst),
  error = function(e) {
    message(e)
    message()
    return(NULL)
  }
)
if (is.null(ref)) {
  message("could not find reference filter parameters for ", inst)
  next
}
ref <- ref %>% filter(quantile == 2.5)
message(paste0("reference filter parameters for instrument = ", inst))
message(paste(capture.output(ref), collapse = "\n"))
message("--------------")

##################
### Bead drift ###
##################
dated_msg("saving bead drift from reference")
filetype <- paste0("SeaFlowDrift_", inst)
project <- cruise
description <- paste0("Bead location drift from reference for ", inst)
beads_files <- list.files(
  file.path(subsample_dir),
  pattern = "last-1-hours.beadSample.parquet",
  full.names = TRUE,
  recursive = TRUE
)
if (length(beads_files) > 0) {
  drift <- dplyr::bind_rows(lapply(beads_files, function(f) {
    arrow::read_parquet(f, col_select = c("D1", "D2", "fsc_small", "pe", "date"))
  })) %>%
    dplyr::filter(
      D1 < ref$beads_D1 + 1.5 * 10^4,
      D2 < ref$beads_D2 + 1.5 * 10^4,
      pe > 5 * 10^4
    ) %>%
    dplyr::group_by(time = lubridate::floor_date(date, "hour")) %>%
    dplyr::summarize(
      D1 = round(100 * (median(D1) - ref$beads_D1) / ref$beads_D1, 3),
      D2 = round(100 * (median(D2) - ref$beads_D2) / ref$beads_D2, 3),
      fsc = round(100 * (median(fsc_small) - ref$beads_fsc_small) / ref$beads_fsc_small, 3)
    )
  if (!dir.exists(dirname(drift_file))) {
    dir_status <- dir.create(dirname(drift_file), recursive = TRUE)
    if (!dir_status) {
      dated_msg(paste0("could not create output directory ", dirname(drift_file)))
      quit(status = 1)
    }
  }
  tmp_drift_file <- mktempname(dirname(drift_file), basename(drift_file))
  fh <- file(tmp_drift_file, open = "wt")
  writeLines(filetype, fh)
  writeLines(project, fh)
  writeLines(description, fh)
  writeLines(paste("RFC3339 timestamp", "NA", "NA", "NA", sep = "\t"), fh)
  writeLines(paste("time", "float", "float", "float", sep = "\t"), fh)
  writeLines(paste("NA", "NA", "NA", "NA", sep = "\t"), fh)
  close(fh)
  readr::write_delim(drift, tmp_drift_file, delim = "\t", col_names = TRUE, append = TRUE)
  file.rename(tmp_drift_file, drift_file)
  dated_msg("saved bead drift from reference")
} else {
  dated_msg("no bead subsample files found")
}

######################################
### Background particle percentage ###
######################################
dated_msg("saving background particles percentage")
if (file.exists(stats_file)) {
  stats <- readr::read_delim(stats_file, delim = "\t", skip = 6)
  filetype <- paste0("SeaFlowBackground_", inst)
  project <- cruise
  description <- paste0("Background particle percentage for instrument ", inst)
  background <- stats %>%
    dplyr::select(time, pop, n_count) %>%
    dplyr::group_by(time) %>%
    dplyr::group_modify(function(x, y) {
      x_unknown <- x[x$pop == "unknown", ]
      if (nrow(x_unknown) > 0) {
        unknown_n <- x_unknown$n_count
      } else {
        unknown_n <- 0
      }
      return(tibble::tibble(
        temp_unknown = unknown_n,
        temp_opp = sum(x$n_count)
      ))
    }) %>%
    dplyr::group_by(time = lubridate::floor_date(time, "hour")) %>%
    dplyr::summarise(
      unknown = sum(temp_unknown),
      opp = sum(temp_opp),
      background = round(100 * unknown / opp, 3)
    )
  if (!dir.exists(dirname(background_file))) {
    dir_status <- dir.create(dirname(background_file), recursive = TRUE)
    if (!dir_status) {
      dated_msg(paste0("could not create output directory ", dirname(background_file)))
      quit(status = 1)
    }
  }
  tmp_background_file <- mktempname(dirname(background_file), basename(background_file))
  fh <- file(tmp_background_file, open = "wt")
  writeLines(filetype, fh)
  writeLines(project, fh)
  writeLines(description, fh)
  writeLines(paste("RFC3339 timestamp", "NA", "NA", "NA", sep = "\t"), fh)
  writeLines(paste("time", "float", "float", "float", sep = "\t"), fh)
  writeLines(paste("NA", "NA", "NA", "NA", sep = "\t"), fh)
  close(fh)
  readr::write_delim(background, tmp_background_file, delim = "\t", col_names = TRUE, append = TRUE)
  file.rename(tmp_background_file, background_file)
  dated_msg("saved background particle percentage")
} else {
  dated_msg("no stats file found")
}

dated_msg("Done")
