job "minio_job" {
  datacenters = ["dc1"]

  type = "service"

  group "minio_group" {
    count = 1

    volume "minio" {
      type = "host"
      source = "minio"
    }

    network {
      port "minio-api" {
        static = 9000
        host_network = "localhost"
      }
      port "minio-console" {
        static = 9001
        host_network = "localhost"
      }
    }

    service {
      name = "minio"
      port = "minio-api"
      check {
        type = "http"
        method = "GET"
        path = "/minio/health/live"
        timeout = "10s"
        interval = "30s"
      }
    }

    task "wait_for_webhook" {
      lifecycle {
        hook = "prestart"
        sidecar = false
      }

      driver = "exec"
      config {
        command = "/local/wait.sh"
      }

      template {
        data = <<EOH
#!/bin/bash

until curl -o /dev/null --silent --fail "http://127.0.0.1:9010/hooks/healthcheck"; do
    echo "webhook server - not ready"
    sleep 5
done
echo "webhook server - ready"
        EOH
        destination = "/local/wait.sh"
        perms = "755"
      }
    }

    task "minio" {
      driver = "exec"
      user = "minio"

      volume_mount {
        volume = "minio"
        destination = "/var/lib/minio"
      }

      template {
        data = <<EOH
# Minio env vars
MINIO_ROOT_USER="{{key "minio/MINIO_ROOT_USER"}}"
MINIO_ROOT_PASSWORD="{{key "minio/MINIO_ROOT_PASSWORD"}}"
MINIO_NOTIFY_WEBHOOK_ENABLE_PRIMARY=on
MINIO_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY="http://127.0.0.1:9010/hooks/minio"
MINIO_NOTIFY_WEBHOOK_QUEUE_DIR=/var/lib/minio/events
        EOH
        destination = "secrets/file.env"
        env = true
      }

      config {
        command = "minio"
        args = [
          "server",
          "/var/lib/minio/data",
          "--address", "127.0.0.1:${NOMAD_PORT_minio_api}",
          "--console-address", "127.0.0.1:${NOMAD_PORT_minio_console}"
        ]
      }

      resources {
        memory = 1000
        cpu = 500
      }
    }
  }
}
