variable "realtime_user" {
  type = string
  default = "ubuntu"
}

job "retrieve-realtime-data" {
  datacenters = ["dc1"]

  type = "batch"

  periodic {
    cron = "*/10 * * * *"  // every 10 minutes
    prohibit_overlap = true
    time_zone = "UTC"
  }

  # No restart attempts
  reschedule {
    attempts = 0
    unlimited = false
  }

  group "retrieve-realtime-data" {
    count = 1

    volume "jobs_data" {
      type = "host"
      source = "jobs_data"
    }

    task "retrieve-realtime-data" {
      driver = "docker"

      volume_mount {
        volume = "jobs_data"
        destination = "/jobs_data"
      }

      config {
        image = "ingest:local"
        command = "/local/run.sh"
        network_mode = "host"
      }

      user = var.realtime_user

      resources {
        memory = 50
        cpu = 300
      }

      template {
        data = <<EOH
{{ key "retrieve-realtime-data/sshprivatekey" }}
        EOH
        destination = "/secrets/sshprivatekey"
        change_mode = "restart"
      }

      template {
        data = <<EOH
#!/usr/bin/env bash
# Sync to shore

retrieve_host="{{ key "retrieve-realtime-data/host" }}"
retrieve_user="{{ key "retrieve-realtime-data/user" }}"

# Convert \\n to true newlines in SSH private key file
# Would put this back in /secrets but can't write there from task
python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n", "\n"))' < /secrets/sshprivatekey > /local/sshprivatekey2
chmod 600 /local/sshprivatekey2

# Retrieve realtime data with rsync
# Make sure remote path exists
rsync -au --stats --progress -e 'ssh -i /local/sshprivatekey2 -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null"' \
  "${retrieve_user}@${retrieve_host}:" /jobs_data/realtime-sync

        EOH
        destination = "local/run.sh"
        perms = "755"
      }
    }
  }
}
