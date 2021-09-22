variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "webhook_job" {
  datacenters = ["dc1"]

  type = "service"

  group "webhook_group" {
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
          # "-verbose",
          "-template",
          "-port", "${NOMAD_PORT_webhook}",
          "-hooks", "${NOMAD_TASK_DIR}/hooks.json"
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
    "execute-command": "${NOMAD_TASK_DIR}/handle_minio_event.sh",
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
        destination = "${NOMAD_TASK_DIR}/hooks.json"
      }

      template {
        data = <<EOH
#!/bin/bash
set -e
echo "I saw $@"
        EOH
        destination = "${NOMAD_TASK_DIR}/handle_minio_event.sh"
        perms = "755"
      }
    }
  }
}
