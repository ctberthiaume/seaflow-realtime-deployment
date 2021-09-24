job "minio" {
  datacenters = ["dc1"]

  type = "service"

  group "minio" {
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
      task = "minio"
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
#MINIO_NOTIFY_WEBHOOK_ENABLE_PRIMARY=on
#MINIO_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY="http://127.0.0.1:9010/hooks/minio"
#MINIO_NOTIFY_WEBHOOK_QUEUE_DIR=/var/lib/minio/events
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

    task "intial_setup" {
      lifecycle {
        hook = "poststart"
        # shouldn't be a sidecar job, just a workaround for the bug detailed in
        # the template below
        sidecar = true
      }

      driver = "exec"
      config {
        command = "/local/setup.sh"
      }

      template {
        data = <<EOH
# Minio env vars
MC_HOST_minio="http://{{key "minio/MINIO_ROOT_USER"}}:{{key "minio/MINIO_ROOT_PASSWORD"}}@127.0.0.1:{{ env "NOMAD_PORT_minio_api" }}"
        EOH
        destination = "secrets/file.env"
        env = true
      }

      template {
        data = <<EOH
#!/bin/bash
set -e

# Check current bucket set
mc ls minio/ || exit 1

# ----------------------
# Create default buckets
# ----------------------
# Where to put input tsdata files
mc mb --ignore-existing "minio/data/" || exit 1
# Time-binned summary bucket
mc mb --ignore-existing "minio/binned/" || exit 1
# Dashboard JSON bucket
mc mb --ignore-existing "minio/dashboard" || exit 1

if mc admin config get minio notify_webhook 2>&1 | grep "endpoint=http://127.0.0.1:9010/hooks/minio"; then
    echo "webhook for http://127.0.0.1:9010/hooks/minio already enabled "
else
    echo "enabling webhook for http://127.0.0.1:9010/hooks/minio"
    mc admin config set minio notify_webhook:1  endpoint="http://127.0.0.1:9010/hooks/minio" queue_dir="/var/lib/minio/events" || exit 1
    # Restart minio
      mc admin service restart minio || exit 1
fi

# Create webhook bucket put events if needed
for bucket in data dashboard; do
  if mc event list "minio/$bucket" 2>&1 | grep 'arn:minio:sqs::1:webhook'; then
      echo "webhook notification event for minio/$bucket already created"
  else
      echo "creating webhook notification event for minio/$bucket at arn:minio:sqs::1:webhook"
      mc event add "minio/$bucket" arn:minio:sqs::1:webhook --event put || exit 1
  fi
done

# Sleep forever to avoid entering unhealthy job state. Just sleeping for more
# than min_healthy_time doesn't seem to be reliable.
# https://www.nomadproject.io/docs/job-specification/update#min_healthy_time
# Workaround for this bug
# https://github.com/hashicorp/nomad/issues/10058
while true
do
  sleep 3600
done
        EOH
        destination = "/local/setup.sh"
        perms = "755"
      }
    }
  }
}
