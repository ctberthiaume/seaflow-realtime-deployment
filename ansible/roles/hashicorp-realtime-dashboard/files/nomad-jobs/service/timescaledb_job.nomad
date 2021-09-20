job "timescaledb_job" {
  datacenters = ["dc1"]

  type = "service"

  group "timescaledb_group" {
    count = 1

    network {
      port "postgres" {
        static = 5432
        host_network = "localhost"
      }
    }

    service {
      name = "timescaledb"
      check {
        task = "timescaledb_task"
        type = "script"
        timeout = "3s"
        interval = "30s"
        command = "/usr/local/bin/pg_isready"
      }
    }

    task "timescaledb_task" {
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
        ports = [ "postgres" ]
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
