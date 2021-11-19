job "ingest" {
  datacenters = ["dc1"]

  type = "batch"

  parameterized {
    meta_required = [
      "bucket",  # minio bucket
      "key"  # minio object key
    ]
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "ingest" {
    count = 1

    task "ingest" {
      driver = "docker"

      user = 472

      config {
        image = "ingest:local"
        args = [
          "${NOMAD_META_bucket}",
          "${NOMAD_META_key}"
        ]
        network_mode = "host"

        mount {
          type = "volume"
          target = "/etc/grafana/provisioning/datasources"
          source = "grafana_datasources"
        }

        mount {
          type = "volume"
          target = "/etc/dashboards"
          source = "grafana_dashboards"
        }
      }

      resources {
        memory = 100
        cpu = 300
      }

      template {
        data = <<EOH
MC_HOST_minio="http://{{key "minio/MINIO_ROOT_USER"}}:{{key "minio/MINIO_ROOT_PASSWORD"}}@127.0.0.1:9000"
GF_SECURITY_ADMIN_PASSWORD="{{ key "grafana/GF_SECURITY_ADMIN_PASSWORD" }}"
PGPASSWORD="{{ key "timescaledb/POSTGRES_PASSWORD" }}"
ROPASSWORD="{{ key "timescaledb/ROPASSWORD" }}"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
GRAFANA_DASHBOARDS_DIR="/etc/dashboards"
GRAFANA_DATASOURCES_DIR="/etc/grafana/provisioning/datasources"
GRAFANA_ADDRESS=127.0.0.1:3000
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=postgres
ROUSER="{{ key "timescaledb/ROUSER" }}"
GEO_LABEL="{{ key "ingest/GEO_LABEL" }}"
        EOH
        destination = "local/file.env"
        env = true
      }
    }
  }
}
