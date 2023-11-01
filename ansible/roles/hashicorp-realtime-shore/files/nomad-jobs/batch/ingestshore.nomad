variable "realtime_user" {
  type    = string
  default = "ubuntu"
}

job "ingestshore" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron             = "02,07,12,17,22,27,32,37,42,47,52,57 * * * *" // every 5 minutes with 2 minute offset
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts  = 1
    unlimited = false
  }

  group "ingestshore" {
    count = 1

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    task "prep" {
      driver = "docker"

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image   = "ctberthiaume/popcycle:local"
        command = "/local/run.sh"
      }

      resources {
        memory = 500
        cpu    = 300
      }

      template {
        data        = <<EOH
#!/usr/bin/env Rscript
library(dplyr, warn.conflicts=FALSE)

# ---------------------------------------------------------------------------- #

parser <- optparse::OptionParser(usage="usage: fixrealtime.R sfl.csv pop.csv")
p <- optparse::parse_args2(parser)
if (length(p$args) < 2) {
  optparse::print_help(parser)
  quit(save="no")
} else {
  sfl_file <- normalizePath(p$args[1])
  pop_file <- normalizePath(p$args[2])
}
sfl <- readr::read_tsv(sfl_file, show_col_types=FALSE, skip = 6)
pop <- readr::read_tsv(pop_file, show_col_types=FALSE, skip = 6)
volumes <- popcycle::create_volume_table(sfl %>% rename(date=time), time_expr=NULL) %>% rename(time=date)

# Add abundance
pop <- dplyr::left_join(pop, volumes, by="time")
pop[, "n_per_uL"] <- pop[, "n_count"] / pop[, "volume_virtualcore"]

pop <- pop %>%
  dplyr::select(time, pop, n_count, n_per_uL, diam_mid, diam_lwr, correction) %>%
  dplyr::rename(abundance=n_per_uL)

# Get filetype and project
con = file(pop_file, "r")
filetype = stringr::str_replace(readLines(con, n = 1), "SeaFlowPop_", "SeaFlowPopAbundance_")
project = readLines(con, n = 1)
close(con)

pop_file_tsdata <- paste0(tools::file_path_sans_ext(pop_file), ".abund-added.tsdata")


writeLines(filetype, stdout())
writeLines(project, stdout())
writeLines("SeaFlow pop data", stdout())
writeLines(paste("ISO8601 timestamp",	"NA",	"NA",	"NA",	"NA",	"NA", "NA", sep="\t"), stdout())
writeLines(paste("time",	"category",	"integer",	"float",	"float",	"float", "float", sep="\t"), stdout())
writeLines(paste("NA", "NA", "NA",	"NA",	"NA",	"NA", "NA", sep="\t"), stdout())
readr::write_delim(pop, stdout(), delim="\t", col_names=TRUE, append=TRUE)

        EOH
        destination = "/local/fixrealtime.R"
        change_mode = "restart"
        perms       = "755"
      }

      template {
        data        = <<EOH
#!/usr/bin/env bash

set -e
shopt -s nullglob

[[ -d /jobs_data/realtime-sync/ ]] || exit

[[ -d /alloc/data/cache ]] && rm -rf /alloc/data/cache

cp -r /jobs_data/realtime-sync/ /alloc/data/cache

# Erase files which aren't tsdata files
find /alloc/data/cache/ -type f -not \( -name '*.tsdata' -o -name '*.tab' \) -exec rm {} \;

while IFS= read -r sflfile; do
  echo "adding abundance for $sflfile" 1>&2
  dir=$(dirname "$sflfile")
  f=$(basename "${sflfile}")
  end=$(echo "${f}" | sed -e 's/sfl.popcycle.//')
  popfile="${dir}/stats-no-abund.${end}"
  newpopfile="${dir}/stats-abund.${end}"
  echo "attempting to use $popfile, $newpopfile" 1>&2
  if [[ -e "$popfile" ]]; then
    echo "found $popfile" 1>&2
    Rscript --slave /local/fixrealtime.R "$sflfile" "$popfile" > "$newpopfile"
    echo "created $newpopfile" 1>&2
    echo "erasing $popfile" 1>&2
    rm "$popfile"
  fi
done < <(find /alloc/data/cache/ -type f -name 'sfl.popcycle.*.tsdata')

        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms       = "755"
      }
    }

    task "export" {
      driver = "docker"

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image        = "ingest:local"
        command      = "/local/run.sh"
        network_mode = "host"
      }

      user = 472

      lifecycle {
        hook    = "poststop"
        sidecar = false
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

shopt -s nullglob

# Upload data

# This string is the first line of the file with lat/lon, should be loaded first
geolabel={{ key "ingest/GEO_LABEL" }}

cd /alloc/data/cache

# Load geo file with lat/lon first
# Assume no joker put a newline in the file name
while IFS= read -r f; do
  echo "checking $f for geo label in first line" 1>&2
  answer=$(head -n 1 "${f}" | grep "^$geolabel$")  # is the first line the geo label?
  echo "grep results = $answer" 1>&2
  if [[ -n "$answer" ]]; then
    echo "$(date): copying geo data to to minio:data/$(dirname ${f})/" 1>&2
    # TODO: minio doesn't like a directory form of "minio:data/./", i.e. can't
    # import file at the root of realtime-sync, they must be in a subdirectory.
    # Fix this hidden constraint.
    rclone --log-level INFO --config /secrets/rclone.config copy --checksum "${f}" "minio:data/$(dirname ${f})/" || exit $?
    sleep 1
  fi
done < <(find . -type f \( -name '*.tsdata' -o -name '*.tab' \))

echo "$(date): copying all ship data to to minio:data/" 1>&2
rclone --log-level INFO --config /secrets/rclone.config copy --checksum /alloc/data/cache "minio:data/" || exit $?

        EOH
        destination = "local/run.sh"
        perms       = "755"
        change_mode = "restart"
      }
    }
  }
}
