variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "subsample-processing" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/10 * * * *"
    prohibit_overlap = true
    time_zone = "UTC"
  }

  group "subsample-processing" {
    count = 1

    # No restart attempts
    restart {
      attempts = 0
    }

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "plot" {
      driver = "docker"

      config {
        image = "ctberthiaume/popcycle:local"
        command = "/local/run.sh"

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

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 2000
        cpu = 300
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Create subsample plots

set -e

subsampledir="{{ key "subsample-processing/subsampledir" }}t"
outdir="/jobs_data/subsample-processing"

echo "subsampledir=${subsampledir}" 1>&2
echo "outdir=${outdir}" 1>&2

Rscript /scripts/subsample-plots.R --subsample "{{ key "subsample-processing/subsampledir" }}" --out "/jobs_data/subsample-processing" 1>&2
        EOH
        destination = "/local/run.sh"
        change_mode = "restart"
        perms = "755"
      }
    }
  }
}
