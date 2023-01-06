variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "minio" {
  datacenters = ["dc1"]

  type = "service"

  group "minio" {
    count = 1

    volume "minio" {
      type = "host"
      source = "minio"
    }

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
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
      port "webhook" {
        static = 9010
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

    service {
      name = "webhook"
      port = "webhook"
      check {
        type = "http"
        method = "GET"
        path = "/hooks/healthcheck"
        port = "webhook"
        timeout = "10s"
        interval = "30s"
      }
    }

    task "webhook" {
      lifecycle {
        hook = "prestart"
        sidecar = true
      }

      driver = "exec"

      config {
        command = "webhook"
        args = [
          "-verbose",
          "-template",
          "-port", "${NOMAD_PORT_webhook}",
          "-hooks", "/local/hooks.json"
        ]
      }

      user = var.realtime_user

      resources {
        memory = 200
        cpu = 300
      }

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      template {
        data = <<EOH
[
  {
    "id": "healthcheck",
    "execute-command": "/bin/true",
    "command-working-directory": "/",
    "response-message": "healthy",
    "response-headers": [
      {
        "name": "Access-Control-Allow-Origin",
        "value": "*"
      }
    ]
  },
  {
    "id": "minio",
    "execute-command": "/local/handle_minio_event.sh",
    "command-working-directory": "/",
    "response-message": "successfully received minio event",
    "response-headers": [
      {
        "name": "Access-Control-Allow-Origin",
        "value": "*"
      }
    ],
    "pass-arguments-to-command": [
      {
        "source": "payload",
        "name": "Records.0.s3.bucket.name"
      },
      {
        "source": "payload",
        "name": "Records.0.s3.object.key"
      }
    ]
  }
]
        EOH
        destination = "/local/hooks.json"
      }

      template {
        data = <<EOH
#!/bin/bash

echo nomad job dispatch --meta "bucket=$1" --meta "key=$2" ingest
nomad job dispatch --meta "bucket=$1" --meta "key=$2" ingest
        EOH
        destination = "/local/handle_minio_event.sh"
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
#MINIO_NOTIFY_WEBHOOK_ENDPOINT_PRIMARY="http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/minio"
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
        memory = 500
        cpu = 500
      }
    }

    task "intial_setup" {
      lifecycle {
        hook = "poststart"
        sidecar = false
      }

      driver = "exec"
      config {
        command = "/local/setup.sh"
      }

      resources {
        memory = 200
        cpu = 500
      }

      template {
        data = <<EOH
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:ListBucket"
      ],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::user-data"]
    },
    {
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::user-data/*"],
      "Sid": ""
    },
    {
      "Action": [
        "s3:ListBucket"
      ],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::misc"]
    },
    {
      "Action": [
        "s3:GetObject"
      ],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::misc/*"],
      "Sid": ""
    }
  ]
}

        EOH
        destination = "local/researcher-policy.json"
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
# Where to put nomad automated job tsdata files
mc mb --ignore-existing "minio/data/" || exit 1
# Where to put user generated input tsdata files
mc mb --ignore-existing "minio/user-data/" || exit 1
# Dashboard JSON bucket
mc mb --ignore-existing "minio/dashboard" || exit 1
# Data to sync to shore
mc mb --ignore-existing "minio/sync" || exit 1
# Useful files
mc mb --ignore-existing "minio/misc" || exit 1

# --------------------------------------------------------------
# Add user to
# - allow uploads/downlaods of data files
# - allow downloads of misc files
# --------------------------------------------------------------
mc admin user add minio {{ key "minio/researcher_user" }} {{ key "minio/researcher_password" }}
mc admin policy add minio researcher-policy /local/researcher-policy.json
mc admin policy set minio researcher-policy user={{ key "minio/researcher_user" }}

# Configure webhooks notification endpoint
echo "waiting for webhook server to come up"
until curl -o /dev/null --silent --fail "http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/healthcheck"; do
    echo "webhook server - not ready"
    sleep 5
done
echo "webhook server - ready"
if mc admin config get minio notify_webhook 2>&1 | grep "endpoint=http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/minio"; then
    echo "webhook for http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/minio already enabled "
else
    echo "enabling webhook for http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/minio"
    mc admin config set minio notify_webhook:1  endpoint="http://127.0.0.1:{{ env "NOMAD_PORT_webhook" }}/hooks/minio" queue_dir="/var/lib/minio/events" || exit 1
    # Restart minio
      mc admin service restart minio || exit 1
fi

# Create webhook bucket put events if needed
for bucket in data dashboard user-data; do
  if mc event list "minio/$bucket" 2>&1 | grep 'arn:minio:sqs::1:webhook'; then
      echo "webhook notification event for minio/$bucket already created"
  else
      echo "creating webhook notification event for minio/$bucket at arn:minio:sqs::1:webhook"
      mc event add "minio/$bucket" arn:minio:sqs::1:webhook --event put || exit 1
  fi
done
        EOH
        destination = "/local/setup.sh"
        perms = "755"
      }
    }
  }
}
