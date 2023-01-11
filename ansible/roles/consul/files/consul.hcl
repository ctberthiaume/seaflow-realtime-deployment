data_dir = "/opt/consul/"

server = true

bootstrap = true

connect {
  enabled = true
}

ports {
  grpc = 8502
}

ui_config {
  enabled = true
}

advertise_addr = "127.0.0.1"

bind_addr = "127.0.0.1"

addresses {
  dns   = "127.0.0.1"
  http  = "127.0.0.1"
  https = "127.0.0.1"
  grpc  = "127.0.0.1"
}

log_file = "/var/log/consul/consul"
