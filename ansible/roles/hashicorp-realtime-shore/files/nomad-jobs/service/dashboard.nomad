job "dashboard" {
  datacenters = ["dc1"]

  type = "service"

  group "dashboard" {
    count = 1

    network {
      port "grafana" {
        static       = 3000
        host_network = "localhost"
      }
      port "postgres" {
        static       = 5432
        host_network = "localhost"
      }
    }

    service {
      name = "grafana"
      port = "grafana"
      task = "grafana"
      check {
        type     = "http"
        method   = "GET"
        path     = "/api/health"
        timeout  = "3s"
        interval = "30s"
      }
    }

    service {
      name = "timescaledb"
      port = "postgres"
      task = "timescaledb"
      check {
        task     = "timescaledb"
        type     = "script"
        timeout  = "3s"
        interval = "30s"
        command  = "/usr/bin/pg_isready"
        args     = ["-U", "postgres"]
      }
    }


    task "setup" {
      driver = "docker"

      user = "root"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image        = "grafana/grafana:local"
        network_mode = "host"
        entrypoint   = ["/bin/bash"]
        args         = ["/local/run.sh"]

        mount {
          type   = "volume"
          target = "/var/lib/grafana"
          source = "grafana_data"
        }

        mount {
          type   = "bind"
          target = "/plugin-zips"
          source = "/var/lib/grafana/plugin-zips"
        }

        mount {
          type   = "volume"
          target = "/etc/dashboards"
          source = "grafana_dashboards"
        }

        mount {
          type   = "volume"
          target = "/etc/grafana/provisioning/dashboards"
          source = "grafana_provisioning_dashboards"
        }
      }

      template {
        data        = <<EOH
#!/bin/bash

# Install plugins
for zipfile in /plugin-zips/*.zip; do
  if [[ ! -d /var/lib/grafana/plugins/$(basename "$zipfile" .zip) ]]; then
    echo "Installing $zipfile"
    unzip "$zipfile" -d /var/lib/grafana/plugins/$(basename "$zipfile" .zip)
    chown -R grafana /var/lib/grafana/plugins/$(basename "$zipfile" .zip)
  fi
done

# Configure dashboard provisioning
cat << EOHINNER > /etc/grafana/provisioning/dashboards/providers.yml
apiVersion: 1

providers:
  - name: dashboards
    folder: 'provisioned'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10 #how often Grafana will scan for changed dashboards
    options:
      path: /etc/dashboards
EOHINNER

# Set ownership for dashboard directory
chown grafana /etc/dashboards
        EOH
        destination = "local/run.sh"
        perms       = "755"
      }

      resources {
        memory = 200
        cpu    = 300
      }
    }

    task "grafana" {
      driver = "docker"

      template {
        data        = <<EOH
GF_SECURITY_ADMIN_PASSWORD="{{ key "grafana/GF_SECURITY_ADMIN_PASSWORD" }}"
ROPASSWORD="{{ key "timescaledb/ROPASSWORD" }}"
        EOH
        destination = "secrets/file.env"
        env         = true
      }

      template {
        data        = <<EOH
GF_LOG_LEVEL=info
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_AUTH_ANONYMOUS_ENABLED=true
GF_AUTH_ANONYMOUS_ORG_NAME="Main Org."
GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=ae3e-plotly-panel
GF_SERVER_HTTP_ADDR=127.0.0.1
GF_SERVER_DOMAIN="{{ key "grafana/domain" }}"
GF_USERS_VIEWERS_CAN_EDIT="{{ key "grafana/GF_USERS_VIEWERS_CAN_EDIT" }}"
GF_USERS_ALLOW_SIGN_UP="{{ key "grafana/GF_USERS_ALLOW_SIGN_UP" }}"
GF_USERS_AUTO_ASSIGN_ORG_ROLE=Editor
PGHOST=127.0.0.1
PGPORT=5432
ROUSER="{{ key "timescaledb/ROUSER" }}"
        EOH
        destination = "local/file.env"
        env         = true
      }

      config {
        image        = "grafana/grafana:local"
        network_mode = "host"
        #ports = [ "grafana" ]

        mount {
          type   = "volume"
          target = "/var/lib/grafana"
          source = "grafana_data"
        }

        mount {
          type   = "volume"
          target = "/etc/dashboards"
          source = "grafana_dashboards"
        }

        mount {
          type   = "volume"
          target = "/etc/grafana/provisioning/datasources"
          source = "grafana_datasources"
        }

        mount {
          type   = "volume"
          target = "/etc/grafana/provisioning/dashboards"
          source = "grafana_provisioning_dashboards"
        }
      }

      resources {
        memory = 300
        cpu    = 300
      }
    }

    task "timescaledb" {
      driver = "docker"

      template {
        data        = <<EOH
# Timescaledb secrets env vars
POSTGRES_PASSWORD="{{key "timescaledb/POSTGRES_PASSWORD"}}"
TIMESCALEDB_TELEMETRY=off
        EOH
        destination = "secrets/file.env"
        env         = true
      }

      config {
        image = "timescale/timescaledb-ha:local"
        args = [
          "-c",
          "listen_addresses=127.0.0.1"
        ]
        network_mode = "host"
        #ports = [ "timescaledb" ]

        mount {
          type   = "volume"
          target = "/home/postgres/pgdata/data"
          source = "postgresql_data"
        }
      }

      resources {
        memory = 300
        cpu    = 300
      }
    }
  }
}
