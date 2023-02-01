#' Get filter parameters matching date or NULL if no params are found within
#' the date range.
get_filter_params <- function(db, dt) {
  filter_id <- popcycle:::add_filter_ids(tibble::tibble(date = dt), db)
  filter_params <- tryCatch(
    get_filter_params_by_id(db, filter_id$filter_id[1]),
    error = function(e) {
      message(e)
      return(NULL)
    }
  )
  return(filter_params)
}

#' Get gating parameters matching date or NULL if no params are found within
#' the date range.
get_gating_params <- function(db, dt) {
  gating_id <- popcycle:::add_gating_ids(tibble::tibble(date = dt), db)
  gates <- tryCatch(
    get_gating_params_by_id(db, gating_id$gating_id[1]),
    error = function(e) {
      message(e)
      return(NULL)
    }
  )
  if (is.null(gates)) {
    return(NULL)
  }
  return(gates$gates.log)
}

plot_opp <- function(opp, title_text) {
  par(mfrow = c(1, 3))
  plot_cyt(opp, para.x = "fsc_small", para.y = "chl_small")
  plot_cyt(opp, para.x = "fsc_small", para.y = "pe")
  title(title_text)
  plot_cyt(opp, para.x = "chl_small", para.y = "pe")
}

plot_vct <- function(evt, beads, opp, filter_params, gates_log, inst) {
  # plot limits for transformed SeaFlow data
  lim2 <- c(1, 10^3.5)

  # classify opp
  opp <- classify_opp(opp, gates_log)

  # Remove file column to disable any facet plot layouts
  opp$file <- NULL

  # Plot gates
  fscchl.g <- plot_cytogram(opp, para.x = "fsc_small", para.y = "chl_small", transform = T, bins = 100, xlim = lim2, ylim = lim2) +
    geom_path(data = as_tibble(gates_log[["prochloro"]]$poly), aes(fsc_small, chl_small), col = "red3") +
    geom_path(data = as_tibble(gates_log[["picoeuk"]]$poly), aes(fsc_small, chl_small), col = "red3")
  fscpe.g <- plot_cytogram(opp, para.x = "fsc_small", para.y = "pe", transform = T, bins = 100, xlim = lim2, ylim = lim2) +
    # geom_path(data=as_tibble(gates_log[["beads"]]$poly), aes(fsc_small, pe), col="red3") +  # I (Annette) gate beads on pe vs chl
    geom_path(data = as_tibble(gates_log[["synecho"]]$poly), aes(fsc_small, pe), col = "red3")
  # Plot vct
  fsc.v <- plot_histogram(opp, para.x = "fsc_small", xlim = lim2)
  chl.v <- plot_histogram(opp, para.x = "chl_small", xlim = lim2)
  pe.v <- plot_histogram(opp, para.x = "pe", xlim = lim2)
  fscchl.v <- plot_vct_cytogram(opp, para.x = "fsc_small", para.y = "chl_small", xlim = lim2, ylim = lim2)
  fscpe.v <- plot_vct_cytogram(opp, para.x = "fsc_small", para.y = "pe", xlim = lim2, ylim = lim2)

  # virtualcore sensitivity
  low <- evt %>% filter(D1 == 0 | D2 == 0) # particles with no D1 or D2 signal
  satur <- evt %>% filter(D1 == max(D1) | D2 == max(D2)) # particles with saturated D1 or D2 signal
  unknown <- opp %>% filter(pop == "unknown" & pop != "beads")
  core <- tibble(
    nosignal = 100 * nrow(low) / nrow(evt),
    saturated = 100 * nrow(satur) / nrow(evt),
    background = 100 * nrow(unknown) / nrow(opp)
  ) %>%
    tidyr::pivot_longer(everything(), names_to = "sensitivity")
  # Plot vc
  sensi <- core %>% ggplot() +
    geom_col(aes(sensitivity, value), alpha = 0.5, fill = "grey") +
    theme_bw() +
    ylim(0, 100) +
    ylab("Total (%)")

  # Error in beads position
  ref <- filter_params %>% filter(quantile == 50)
  vc <- beads %>%
    filter(D1 < ref$beads_D1 + 1.5 * 10^4 & D2 < ref$beads_D2 + 1.5 * 10^4 & pe > 5 * 10^4) %>%
    summarize(
      D1 = 100 * (median(D1) - ref$beads_D1) / ref$beads_D1,
      D2 = 100 * (median(D2) - ref$beads_D2) / ref$beads_D2,
      fsc = 100 * (median(fsc_small) - ref$beads_fsc_small) / ref$beads_fsc_small
    ) %>%
    tidyr::pivot_longer(everything(), names_to = "pmt", values_to = "drift")

  # Plot drift
  drift <- vc %>% ggplot() +
    geom_col(aes(pmt, drift), alpha = 0.5, fill = "red3") +
    geom_hline(yintercept = 0, lty = 2) +
    theme_bw() +
    ylim(-50, 50) +
    ylab("drift (%)")

  p <- ggpubr::ggarrange(chl.v, fscchl.v, fscchl.g, fsc.v, fscpe.v, fscpe.g, pe.v, sensi, drift, nrow = 3, ncol = 3, common.legend = T)
  title <- paste0(inst, " / ", min(evt$date), " - ", max(evt$date))
  p <- ggpubr::annotate_figure(p, top = ggpubr::text_grob(title, face = "bold", size = 14))
  return(p)
}

# optparse may not be installed globally so look for renv directory using optparse
args <- commandArgs(trailingOnly = TRUE)
renv_loc <- args == "--renv"
if (any(renv_loc)) {
  renv_idx <- which(renv_loc)
  if (length(args) > renv_idx) {
    proj_dir <- renv::activate(args[renv_idx + 1])
    message("activated renv directory ", proj_dir)
  }
}

parser <- optparse::OptionParser(usage = "usage: plot-subsamples.R --repo-db-url URL --subsample-dir DIR --out-dir DIR")

parser <- optparse::add_option(parser, c("--repo-db-url"),
  type = "character", default = "https://github.com/seaflow-uw/realtime-dbs",
  help = "Realtime Popcycle database git repository URL.",
  metavar = "URL"
)
parser <- optparse::add_option(parser, c("--subsample"),
  type = "character", default = "",
  help = "Subsample data directory. Required.",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, c("--out"),
  type = "character", default = "",
  help = "Output directory. Required.",
  metavar = "DIR"
)
parser <- optparse::add_option(parser, "--renv",
  type = "character", default = "", metavar = "dir",
  help = "Optional renv directory to use. Requires the renv package."
)

p <- optparse::parse_args2(parser, args = args)
if (p$options$subsample == "" || p$options$out == "") {
  message("error: must specify all of --subsample, --out")
  optparse::print_help(parser)
  quit(save = "no", status = 10)
}

library(popcycle)
library(tidyverse)

subsample_dir <- p$options$subsample
out_dir <- p$options$out
repo_db_url <- p$options$repo_db_url

if (!dir.exists(subsample_dir)) {
  message(paste0(subsample_dir, " does not exist"))
  quit(save = FALSE, status = 11)
}

if (!dir.exists(out_dir)) {
  message(paste0("creating output directory ", out_dir))
  dir.create(out_dir, recursive = TRUE)
}

repo_dir <- file.path(out_dir, "realtime-dbs")

if (!dir.exists(repo_dir)) {
  status <- system2("git", c("clone", repo_db_url, repo_dir))
  if (status == 127) {
    stop("could not clone ", repo_db_url)
  }
}

orig_dir <- getwd()
setwd(repo_dir)
status <- system2("git", c("pull"))
if (status == 127) {
  stop("could not pull latest for ", repo_db_url)
}
setwd(orig_dir)

dbs <- list.files(file.path(repo_dir, "dbs"), pattern = ".*\\.db$", full.names = TRUE)
message("found ", length(dbs), " db files")
for (db in dbs) {
  message("looking for subsampled particle data for ", db)
  match <- stringr::str_match(basename(db), pattern = "(.+)_([^_]+)\\.db$")
  if (ncol(match) != 3) {
    message("could not parse database name ", basename(db))
    next
  }
  cruise <- match[1, 2]
  inst <- match[1, 3]

  data_dir <- file.path(subsample_dir, cruise, inst)
  if (!dir.exists(data_dir)) {
    message(glue::glue("no subsampled data directory for {cruise}/{inst}"))
    next
  }
  message("found subsampled particle data folder in ", data_dir)
  cruise_out_dir <- file.path(out_dir, cruise, inst)
  if (!dir.exists(cruise_out_dir)) {
    dir.create(cruise_out_dir, recursive = T)
  }

  # Get reference filter parameters
  # reference_filter_params <- tryCatch(
  #   read_reference_filter_params(inst),
  #   error = function(e) {
  #     message(e)
  #     return(NULL)
  #   }
  # )
  # Force 740 reference filter params
  # TODO: should we have 130 reference filter params too?
  reference_filter_params <- tryCatch(
    read_reference_filter_params(inst),
    error = function(e) {
      message(e)
      message()
      return(NULL)
    }
  )
  if (is.null(reference_filter_params)) {
    message("could not find reference filter parameters for ", inst)
    next
  }
  message(paste0("using reference filter parameters for instrument ", inst))

  for (folder in sort(list.dirs(data_dir, full.names = T, recursive = F))) {
    message("")
    message("  folder = ", folder)
    date_str <- basename(folder)
    earliest_date <- lubridate::ymd_hms(date_str)

    # Read parquet files
    beads_file <- list.files(folder, pattern = ".*\\.beadSample\\.parquet$", full.names = T)
    if (length(beads_file) != 1) {
      message("  could not find beads data file")
      next
    }
    message("  found bead data in ", beads_file[1])

    evt_file <- list.files(folder, pattern = ".*\\.fullSample\\.parquet$", full.names = T)
    if (length(evt_file) != 1) {
      message("  could not find beads data file")
      next
    }
    message("  found full EVT data in ", evt_file[1])

    opp_file <- list.files(folder, pattern = ".*\\.opp\\.sample\\.parquet$", full.names = T)
    if (length(opp_file) != 1) {
      message("  could not find OPP data file")
      next
    }
    message("  found OPP data in ", opp_file[1])

    # Get filter and gating params for this date range
    filter_params <- get_filter_params(db, earliest_date)
    if (is.null(filter_params)) {
      message("  could not find filter params for timestamp", date_str)
      next
    }
    gates_log <- get_gating_params(db, earliest_date)
    if (is.null(gates_log)) {
      message("  could not find gating params for timestamp", date_str)
      next
    }

    # Beads filter plots
    beads_filter_img_file <- file.path(cruise_out_dir, glue::glue("{date_str}-beads_filter_cytograms.png"))
    if (!file.exists(beads_filter_img_file)) {
      message("  saving ", beads_filter_img_file)
      png(beads_filter_img_file, width = 1200, height = 900, res = 150)
      beads <- arrow::read_parquet(beads_file[1])
      try(plot_filter_cytogram(beads, filter_params))
      mtext(paste0(inst, "/", date_str), 3, 2, cex = 1)
      dev.off()
    }

    # Full EVT filter plots
    evt_filter_img_file <- file.path(cruise_out_dir, glue::glue("{date_str}-full_filter_cytograms.png"))
    if (!file.exists(evt_filter_img_file)) {
      message("  saving ", evt_filter_img_file)
      png(evt_filter_img_file, width = 1200, height = 900, res = 150)
      evt <- arrow::read_parquet(evt_file[1])
      try(plot_filter_cytogram(evt, filter_params))
      mtext(paste0(inst, "/", date_str), 3, 2, cex = 1)
      dev.off()
    }

    # OPP plots
    opp_img_file <- file.path(cruise_out_dir, glue::glue("{date_str}-opp_cytograms.png"))
    if (!file.exists(opp_img_file)) {
      message("  saving ", opp_img_file)
      png(opp_img_file, width = 1200, height = 400, res = 150)
      opp <- arrow::read_parquet(opp_file[1])
      try(plot_opp(opp, paste0(inst, "/", date_str)))
      dev.off()
    }

    # Plot gates with OPP
    vct_img_file <- file.path(cruise_out_dir, glue::glue("{date_str}-vct_cytograms.png"))
    if (!file.exists(vct_img_file)) {
      message("  saving ", vct_img_file)
      png(vct_img_file, width = 1200, height = 1200, res = 150)
      opp <- arrow::read_parquet(opp_file[1]) %>% select(-c(file_id))
      try(print(plot_vct(evt, beads, opp %>% filter(q50), reference_filter_params, gates_log, inst)))
      dev.off()
    }
  }
}
