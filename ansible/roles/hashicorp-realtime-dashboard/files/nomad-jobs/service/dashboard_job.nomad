job "dashboard" {
  datacenters = ["dc1"]

  type = "service"

  group "dashboard" {
    count = 1

    network {
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
      task = "grafana"
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
      task = "timescaledb"
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
ROPASSWORD="{{ key "timescaledb/ROPASSWORD" }}"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_SERVER_HTTP_ADDR=127.0.0.1
PGHOST=127.0.0.1
PGPORT=5432
ROUSER="{{ key "timescaledb/ROUSER" }}"
        EOH
        destination = "local/file.env"
        env = true
      }

      template {
        data = <<EOH
apiVersion: 1

providers:
- name: 'default'
  orgId: 1
  folder: ''
  type: file
  disableDeletion: false
  updateIntervalSeconds: 10 #how often Grafana will scan for changed dashboards
  options:
    path: /etc/dashboards
        EOH
        destination = "/etc/grafana/provisioning/dashboards/providers.yml"
      }

      config {
        image = "grafana/grafana:local"
        network_mode = "host"
        #ports = [ "grafana" ]

        mount {
          type = "volume"
          target = "/var/lib/grafana"
          source = "grafana_data"
        }

        mount {
          type = "volume"
          target = "/etc/dashboards"
          source = "grafana_dashboards"
        }

        mount {
          type = "volume"
          target = "/etc/grafana/provisioning/datasources"
          source = "grafana_datasources"
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
        args = [
          "-c",
          "listen_addresses=127.0.0.1"
        ]
        network_mode = "host"
        #ports = [ "timescaledb" ]

        mount {
          type = "volume"
          target = "/var/lib/postgresql/data"
          source = "postgresql_data"
        }
      }

      resources {
        memory = 1000
        cpu = 300
      }
    }
  }
}
