variable "realtime_user" {
  type    = string
  default = "ubuntu"
}

job "shareloc" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron             = "*/5 * * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  parameterized {
    meta_required = ["cruise"]
  }

  group "copyloc" {
    count = 1

    # No restart attempts
    restart {
      attempts = 0
    }

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    task "copyloc" {
      driver = "docker"

      config {
        image   = "caddy/caddy:local"
        command = "${NOMAD_TASK_DIR}/copy.sh"

        mount {
          type   = "bind"
          target = "/jobs_data"
          source = "/data/jobs_data"
          volume_options {
            no_copy = true
          }
        }

        mount {
          type   = "volume"
          target = "/srv/public_files"
          source = "caddy_file_server_data"
        }
      }

      resources {
        memory = 50
        cpu    = 300
      }

      template {
        data        = <<EOH
#!/bin/sh
src="/jobs_data/realtime-sync/cruisemic/${NOMAD_META_cruise}/${NOMAD_META_cruise}-geo.tab"
dst=/srv/public_files/cruiseloc/
if [[ ! -d "$dst" ]]; then
  echo "creating $dst/"
  mkdir $dst
  status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "error creating $dst"
    exit "$status"
  fi
fi
echo "copying $src to $dst"
cp "$src" "$dst/"
exit $?

        EOH
        destination = "${NOMAD_TASK_DIR}/copy.sh"
        change_mode = "restart"
        perms       = "755"
      }
    }
  }
}
