job "caddy" {
  datacenters = ["dc1"]

  type = "service"

  group "caddy" {
    count = 1

    network {
      port "caddy-admin" {
        static = 2019
        host_network = "localhost"
      }
      port "http" {
        static = 80
        host_network = "public"
      }
      port "https" {
        static = 443
        host_network = "public"
      }
    }

    service {
      name = "caddy"

      check {
        name     = "alive"
        type     = "tcp"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "caddy" {
      driver = "docker"

      config {
        image = "caddy/caddy:local"
        command = "caddy"
        args = [ "run", "--environ", "--config", "/local/Caddyfile" ]
        network_mode = "host"
 
        mount {
          type = "volume"
          target = "/data"
          source = "caddy_data"
        }

        mount {
          type = "volume"
          target = "/srv/public_files"
          source = "cadd_file_server_data"
        }
      }

      resources {
        memory = 50
        cpu = 300
      }

      template {
        data = <<EOH
# grafana
# for HTTP localhost use something like "http://localhost:3001"
# for automatic HTTPS public site use the bare domain name like "example.com"
"{{ key "caddy/grafana-site-address" }}" {
  redir /datafiles /datafiles/

  handle /datafiles/* {
    basicauth {
      {{ key "caddy/files-user" }} {{ key "caddy/files-password-hash" }} {{ key "caddy/files-password-salt" }}
    }
    root * /srv/public_files
    uri strip_prefix /datafiles
    file_server {
      browse
    }
  }

  handle {
    reverse_proxy 127.0.0.1:3000
  }
}
        EOH
        destination = "/local/Caddyfile"
      }
    }
  }
}
