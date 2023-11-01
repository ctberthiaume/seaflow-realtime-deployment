job "caddy" {
  datacenters = ["dc1"]

  type = "service"

  group "caddy" {
    count = 1

    network {
      port "caddy-admin" {
        static       = 2019
        host_network = "localhost"
      }
    }

    service {
      name = "caddy"

      check {
        name     = "alive"
        type     = "http"
        port     = "caddy-admin"
        path     = "metrics"
        interval = "10s"
        timeout  = "2s"
      }
    }

    volume "jobs_data" {
      type   = "host"
      source = "jobs_data"
    }

    task "caddy" {
      driver = "docker"

      config {
        image        = "caddy/caddy:local"
        command      = "caddy"
        args         = ["run", "--environ", "--config", "/local/Caddyfile"]
        network_mode = "host"

        mount {
          type   = "volume"
          target = "/data"
          source = "caddy_data"
        }

        mount {
          type   = "volume"
          target = "/srv/public_files"
          source = "caddy_file_server_data"
        }
      }

      volume_mount {
        volume      = "jobs_data"
        destination = "/jobs_data"
      }

      resources {
        memory = 50
        cpu    = 300
      }

      template {
        data        = <<EOH
# grafana
# for HTTP localhost use something like "http://localhost:3001"
# for HTTP just enter the port ":3001"
# for automatic HTTPS public site use the bare domain name like "example.com"
{{ key "caddy/grafana-site-address" }} {
  redir /datafiles /datafiles/
  redir /realtime-data /realtime-data/

  handle /datafiles/* {
    root * /srv/public_files
    uri strip_prefix /datafiles
    file_server {
      browse
    }
  }

  handle /realtime-data/* {
    root * /jobs_data/
    uri strip_prefix /realtime-data
    file_server {
      browse
    }
  }

  handle {
    reverse_proxy 127.0.0.1:3000
  }
}

# minio web console
:4000 {
  reverse_proxy 127.0.0.1:9001
}

# consul web console
:8800 {
  reverse_proxy 127.0.0.1:8500
}

# nomad web console
:4747 {
  reverse_proxy 127.0.0.1:4646
}
        EOH
        destination = "/local/Caddyfile"
      }
    }
  }
}
