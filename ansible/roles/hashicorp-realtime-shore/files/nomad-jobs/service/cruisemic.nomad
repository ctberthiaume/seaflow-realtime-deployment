variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "cruisemic" {
  datacenters = ["dc1"]

  type = "service"

  group "cruisemic" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    service {
      name = "cruisemic"
    }

    task "cruisemic" {
      driver = "exec"

      user = var.realtime_user

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash

CRUISE="{{ key "cruise/name" }}"
PARSER="{{ key "cruisemic/parser" }}"
PORT="{{ key "cruisemic/port" }}"
INTERVAL="{{ key "cruisemic/interval" }}"

cruisemic --version

cruisemic \
  -parser "${PARSER}" \
  -name "${CRUISE}" \
  -udp -port "${PORT}" \
  -interval "${INTERVAL}" \
  -dir "/jobs_data/cruisemic/${CRUISE}" \
  -quiet -flush
        EOH
        destination = "local/run.sh"
        perms = "755"
        change_mode = "restart"
      }

      config {
        command = "/local/run.sh"
      }
    }
  }
}
