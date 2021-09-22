job "dashboard_job" {
  datacenters = ["dc1"]

  type = "service"

  group "dashboard_group" {
    count = 1

    network {
      mode = "bridge"
      port "grafana" {
        static = 3000
        host_network = "localhost"
      }
      port "postgres" {
        static = 5432
        host_network = "localhost"
      }
    }

    service {
      name = "grafana"
      port = "grafana"
      check {
        type = "http"
        method = "GET"
        path = "/api/health"
        timeout = "3s"
        interval = "30s"
      }
    }

    service {
      name = "timescaledb"
      port = "postgres"
      check {
        task = "timescaledb"
        type = "script"
        timeout = "3s"
        interval = "30s"
        command = "/usr/local/bin/pg_isready"
      }
    }

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
        EOH
        destination = "local/file.env"
        env = true
      }

      config {
        image = "grafana/grafana:local"
        #network_mode = "host"
        ports = [ "grafana" ]

        mount {
          type = "volume"
          target = "/var/lib/grafana"
          source = "lib_grafana"
        }
      }

      resources {
        memory = 1000
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
        #network_mode = "host"
        ports = [ "timescaledb" ]

        mount {
          type = "volume"
          target = "/var/lib/postgresql/data"
          source = "lib_postgresql"
        }
      }

      resources {
        memory = 1000
        cpu = 300
      }
    }
  }
}
