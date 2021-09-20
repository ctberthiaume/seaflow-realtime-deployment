job "caddy_job" {
  datacenters = ["dc1"]

  type = "service"

  group "caddy_group" {
    count = 1

    # network {
    #   port "caddy-admin" {
    #     static = 2019
    #     host_network = "localhost"
    #   }
    #   port "caddy-http" {
    #     static = 80
    #     host_network = "public"
    #   }
    #   # port "caddy-https" {
    #   #   static = 443
    #   #   host_network = "public"
    #   # }
    # }

    # service {
    #   name = "caddy"
    #   port = "caddy-http"
    #   # check {
    #   #   type = "http"
    #   #   method = "GET"
    #   #   path = "/config"
    #   #   port = "caddy-admin"
    #   #   timeout = "3s"
    #   #   interval = "30s"
    #   # }
    # }

    volume "caddy_home" {
      type = "host"
      source = "caddy_home"
    }

    task "caddy" {
      driver = "exec"
      user = "caddy"

      env {
        HOME = "/var/lib/caddy"
      }

      volume_mount {
        volume = "caddy_home"
        destination = "/var/lib/caddy"
      }

      template {
        data = <<EOH
"{{ key "caddy/grafana-site-address" }}"

reverse_proxy 127.0.0.1:3000
        EOH
        destination = "local/Caddyfile"
      }

      config {
        command = "caddy"
        args = [ "run", "--environ", "--config", "local/Caddyfile" ]
        cap_add = ["net_bind_service"]
      }
    }
  }
}
