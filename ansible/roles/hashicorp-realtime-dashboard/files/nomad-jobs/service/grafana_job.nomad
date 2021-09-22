job "dashboard_job" {
  datacenters = ["dc1"]

  type = "service"

  group "dashboard_group" {
    count = 1

    # network {
    #   port "caddy-admin" {
    #     static = 2019
    #     host_network = "localhost"
    #   }
    #   port "caddy-http" {
    #     static = 80
    #     host_network = "public"
    #   }
    #   port "caddy-https" {
    #     static = 443
    #     host_network = "public"
    #   }
    #   port "grafana-private" {
    #     static = 3000
    #     host_network = "localhost"
    #   }
    #   port "postgres" {
    #     static = 5432
    #     host_network = "localhost"
    #   }
    # }

    # service {
    #   name = "caddy-http"
    #   port = "caddy-http"
    #   check {
    #     type = "http"
    #     method = "GET"
    #     path = "/config"
    #     port = "caddy-admin"
    #     timeout = "3s"
    #     interval = "30s"
    #   }
    # }

    # service {
    #   name = "caddy-https"
    #   port = "caddy-https"
    #   check {
    #     type = "http"
    #     method = "GET"
    #     path = "/config"
    #     port = "caddy-admin"
    #     timeout = "3s"
    #     interval = "30s"
    #   }
    # }

    # service {
    #   name = "grafana"
    #   port = "grafana-private"
    #   check {
    #     type = "http"
    #     method = "GET"
    #     path = "/api/health"
    #     port = "grafana-private"
    #     timeout = "3s"
    #     interval = "30s"
    #   }
    # }

    # service {
    #   name = "timescaledb"
    #   port = "postgres"
    #   check {
    #     task = "timescaledb"
    #     type = "script"
    #     timeout = "3s"
    #     interval = "30s"
    #     command = "/usr/local/bin/pg_isready"
    #   }
    # }

#     volume "caddy_home" {
#       type = "host"
#       source = "caddy_home"
#     }

#     task "caddy" {
#       driver = "docker"

#       template {
#         data = <<EOH
# {
#     # This binds to all interfaces. Make sure something above this limits to private address.
#     # Doing this to make caddy admin interface available to nomad for health checks on the
#     # nomad client host. Still restricted to localhost by virtue of the port mapping in the nomad
#     # job to the "localhost" network.
#     admin :2019
# }

# "{{ key "caddy/grafana-site-address" }}"

# reverse_proxy 127.0.0.1:3000
#         EOH
#         destination = "${NOMAD_TASK_DIR}/Caddyfile"
#       }

#       config {
#         image = "caddy/caddy:local"
#         command = "caddy"
#         args = [ "run", "--environ", "--config", "${NOMAD_TASK_DIR}/Caddyfile" ]
#         ports = [ "caddy-admin", "caddy-http" ]
#         mount {
#           type = "volume"
#           target = "/data"
#           source = "lib_caddy"
#         }
#         cap_add = ["net_bind_service"]
#       }
#     }

    task "grafana" {
      driver = "docker"

      template {
        data = <<EOH
GF_SECURITY_ADMIN_PASSWORD="{{ key "grafana/GF_SECURITY_ADMIN_PASSWORD" }}"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_SERVER_HTTP_ADDR=127.0.0.1
        EOH
        destination = "local/file.env"
        env = true
      }

      config {
        image = "grafana/grafana:local"
        network_mode = "host"

        mount {
          type = "volume"
          target = "/var/lib/grafana"
          source = "lib_grafana"
        }
      }

      resources {
        memory = 2000
        cpu = 2000
      }
    }

    task "timescaledb" {
      driver = "docker"

      template {
        data = <<EOH
# Timescaledb secrets env vars
POSTGRES_PASSWORD="{{key "timescaledb/POSTGRES_PASSWORD"}}"
TIMESCALEDB_TELEMETRY=off
        EOH
        destination = "secrets/file.env"
        env = true
      }

      config {
        image = "timescale/timescaledb:local"
        network_mode = "host"
        mount {
          type = "volume"
          target = "/var/lib/postgresql/data"
          source = "lib_postgresql"
        }
      }

      resources {
        memory = 2000
        cpu = 300
      }
    }
  }
}
