variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "ingestshore" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/15 * * * *"  // every 15 minutes
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 1
    unlimited = false
  }

  group "ingestshore" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "prep" {
      driver = "docker"

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image = "ctberthiaume/popcycle:local"
        command = "/local/run.sh"
      }

      resources {
        memory = 500
        cpu = 300
      }

      template {
        data = <<EOH
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
pop_idx <- (pop$pop == "prochloro") | (pop$pop == "synecho")
pop[, "n_per_uL"] <- pop[, "n_count"] / pop[, "volume_large"]
pop[pop_idx, "n_per_uL"] <- pop[pop_idx, "n_count"] / pop[pop_idx, "volume_small"]

pop <- pop %>%
  dplyr::select(time, pop, n_count, n_per_uL, diam_mid, diam_lwr) %>%
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
writeLines(paste("ISO8601 timestamp",	"NA",	"NA",	"NA",	"NA",	"NA", sep="\t"), stdout())
writeLines(paste("time",	"category",	"integer",	"float",	"float",	"float", sep="\t"), stdout())
writeLines(paste("NA", "NA", "NA",	"NA",	"NA",	"NA", sep="\t"), stdout())
readr::write_delim(pop, stdout(), delim="\t", col_names=TRUE, append=TRUE)

        EOH
        destination = "/local/fixrealtime.R"
        change_mode = "restart"
        perms = "755"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

set -e

[[ -d /jobs_data/realtime-sync/ ]] || exit

[[ -d /alloc/data/cache ]] && rm -rf /alloc/data/cache
mkdir /alloc/data/cache

for dir in /jobs_data/realtime-sync/*; do
  [[ ! -d "$dir" ]] && continue
  cruise=$(basename "$dir")
  mkdir "/alloc/data/cache/${cruise}"

  find /jobs_data/realtime-sync/ -type f \( -name '*.tsdata' -o -name '*.tab' \) -exec cp {} "/alloc/data/cache/${cruise}/" \;

  for sflfile in "/alloc/data/cache/${cruise}/"sfl.popcycle.*.tsdata; do
    echo "adding abundance for $sflfile"
    f=$(basename "${sflfile}")
    end=$(echo "${f}" | sed -e 's/sfl.popcycle.//')
    popfile="/alloc/data/cache/${cruise}/stats-no-abund.${end}"
    newpopfile="/alloc/data/cache/${cruise}/stats-abund.${end}"
    echo "using $popfile, $newpopfile"
    if [[ -e "$popfile" ]]; then
      Rscript --slave /local/fixrealtime.R "$sflfile" "$popfile" > "$newpopfile"
      echo "created $newpopfile"
    fi
  done
done

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
        memory = 50
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

shopt -s nullglob

# Upload data

# This string is the first line of the file with lat/lon, should be loaded first
geolabel={{ key "ingest/GEO_LABEL" }}

cd /alloc/data/cache

for cruise in *; do
  [[ ! -d "$cruise" ]] && continue

  # Remove any SeaFlow pop data with no abundance
  for f in "${cruise}"/stats-no-abund*.tsdata; do
    echo "erasing ${f}" 1>&2
    rm "${f}" || exit $?
  done

  # Load geo file with lat/lon first
  # Assume no joker put a newline in the file name
  while IFS= read -r f; do
    echo "checking $f for geo label in first line" 1>&2
    answer=$(head -n 1 "${f}" | grep "^$geolabel$")  # is the first line the geo label?
    echo "grep results = $answer" 1>&2
    if [[ -n "$answer" ]]; then
      echo "$(date): copying geo data to to minio:data/$(dirname ${f})/" 1>&2
      rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
        "${f}" \
        "minio:data/$(dirname ${f})/" || exit $?
    fi
  done < <(find "${cruise}" -type f \( -name '*.tsdata' -o -name '*.tab' \))

  echo "$(date): copying ship data to to minio:data/${cruise}" 1>&2
  rclone --log-level INFO --config /secrets/rclone.config copy --checksum \
    "${cruise}" \
    "minio:data/${cruise}/" || exit $?
done

        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }
    }
  }
}
