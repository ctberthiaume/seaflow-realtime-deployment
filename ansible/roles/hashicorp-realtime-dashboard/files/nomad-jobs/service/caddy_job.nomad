job "caddy_job" {
  datacenters = ["dc1"]

  type = "service"

  group "caddy_group" {
    count = 1

    network {
      port "caddy-admin" {
        static = 2019
        host_network = "public"
      }
      port "http" {
        static = 80
        host_network = "public"
      }
      port "https" {
        static = 443
        host_network = "public"
      }
    }

    service {
      name = "caddy"

      check {
        name     = "alive"
        type     = "tcp"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }

      # check {
      #   name     = "alive"
      #   type     = "tcp"
      #   port     = "https"
      #   interval = "10s"
      #   timeout  = "5s"
      # }
    }

    volume "caddy_home" {
      type = "host"
      source = "caddy_home"
    }

    task "caddy" {
      driver = "docker"

      config {
        image = "caddy/caddy:local"
        command = "caddy"
        args = [ "run", "--environ", "--config", "${NOMAD_TASK_DIR}/Caddyfile" ]
        network_mode = "host"
 
        mount {
          type = "volume"
          target = "/data"
          source = "lib_caddy"
        }
        cap_add = ["net_bind_service"]
      }

      template {
        data = <<EOH
"{{ key "caddy/grafana-site-address" }}" {
  reverse_proxy 127.0.0.1:3000
}

:8800 {
  reverse_proxy 127.0.0.1:8500
}

:4747 {
  reverse_proxy 127.0.0.1:4646
}
        EOH
        destination = "local/Caddyfile"
      }
    }
  }
}
