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

      # check {
      #   name     = "alive"
      #   type     = "tcp"
      #   port     = "https"
      #   interval = "10s"
      #   timeout  = "5s"
      # }
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
        #cap_add = ["net_bind_service"]
      }

      template {
        data = <<EOH
# grafana
"{{ key "caddy/grafana-site-address" }}" {
  reverse_proxy grafana.service.consul:3000
}
        EOH
        destination = "/local/Caddyfile"
      }
    }
  }
}
