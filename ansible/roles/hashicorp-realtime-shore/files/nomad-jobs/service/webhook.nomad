variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "webhook" {
  datacenters = ["dc1"]

  type = "service"

  group "webhook" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    network {
      port "webhook" {
        static = 9010
        host_network = "localhost"
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
  }
}
