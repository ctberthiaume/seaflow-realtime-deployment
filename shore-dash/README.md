### Install Ansible

```sh
uv sync
```

### Configure Ansible and consul

First create a host file in `inventories` for Ansible.

Then copy the file `consul_state/consul_state_shore.example.json.j2` to `consul_state/consul_state_shore.json.j2` and update configuration values for your setup. Make sure to set "caddy/grafana-site-address", "grafana/domain", and "grafana/root_url".

If running with a public domain name, set `caddy/grafana-site-address` and `grafana/GF_SERVER_DOMAIN` to the domain name, e.g. `cooldash.com`. Set `grafana/SERVER_ROOT_URL` to the full URL with that domain, e.g. `httpd://cooldash.com/`.

If running on a local test server, and assuming you want to access Grafana on port 3001, set `caddy/grafana-site-address` to `:3001`. Set `GF_SERVER_DOMAIN` to the IP or hostname of the test server, e.g. `192.168.1.10` or the local DNS name for that server. Set `GF_SERVER_ROOT_URL` to `http://192.168.1.10:3001` or `http://testhost:3001` if the test server has a DNS name of `testhost`.

Also copy `vault/consul_state_shore_secrets.example.yaml` to `vault/consul_state_shore_secrets.yaml`, encrypt with `ansible-vault encrypt`, and then edit with `ansible-vault edit`. The values in `vault/consul_state_shore_secrets.yaml` will replace the template placeholders in `consul_state/consul_state_shore.json.j2`. To ensure your IDE / LLM does not see your secret values it's important to encrypt first then edit the encrypted copy, rather than modify a plain text file first then encrypt later.

The Caddy fileserver password hash in the secrets file (`caddy/files-password-hash`) can be created with the Caddy subcommand `caddy hash-password`.

```sh
# Create Caddy password hash
caddy hash-password
# Encrypt secrets file and update values
uv run ansible-vault ecrypt vault/consul_state_shore_secrets.yaml
uv run ansible-edit vault/consul_state_shore_secrets.yaml
```

### Provision with Ansible

```sh
uv run ansible-playbook -i inventories/host.yaml playbook-realtime-shore.yaml
```

If consul configuration values change in the future, you can redeploy them by specifying the `deploy-consul-kv` tag.

```sh
uv run ansible-playbook -i inventories/host.yaml --tags deploy-consul-kv -K playbook-shore-dash.yaml
```

### Start nomad jobs

SSH into the server and start Nomad jobs.

#### minio

```sh
nomad job run /etc/realtime/nomad-jobs/service/minio.nomad
# Confirm it's working
rclone lsd minio:
```

#### caddy

```sh
nomad job run /etc/realtime/nomad-jobs/service/caddy_shore.nomad
```

#### dashboard (grafana, timescaledb/postgres)

```sh
nomad job run /etc/realtime/nomad-jobs/service/dashboard.nomad
```

#### retrieve-realtime-data

```sh
nomad job run /etc/realtime/nomad-jobs/batch/retrieve-realtime-data.nomad
```

#### Data ingest jobs

Once has been retrieved from the sync server with `retrieve-realtime-data`, it must be ingested into the database and Grafana. A periodic job, `ingestshore`, uploads TSDATA files to minio. When minio receives a new or changed file, it fires a webhook notification to the webhook server started in the `dashboard` service job. In this way, minio is where we keep track of which files have been updated and need to be imported into Postgresql and Grafana. To import data, the webhook server will start an `ingest` job parameterized with the location of the new file.

```sh
# Start the template ingest job. Parameterized versions of this job will be
# started for new or updated files by ingestshore -> webhook -> ingest
nomad job run /etc/realtime/nomad-jobs/batch/ingest.nomad
nomad job run /etc/realtime/nomad-jobs/batch/ingestshore.nomad
```

Once new data has been imported there will be a new database in Postgresql for the cruise and corresponding new data sources and dashboards availabable in Grafana.

#### Subsample

Subsampled EVT and OPP data will be processed by this job and results will be available through Caddy file server end points (see Caddy config).

```sh
nomad job run /etc/realtime/nomad-jobs/batch/subsample-processing.nomad
```

### Nomad job control and troubleshooting

To see all nomab jobs, use `nomab job status`. For each job you can view its status with `nomad job status JOBID`. Each job must be allocated some resources to run, which will be listed in the job status output. View each allocation's status with `nomad alloc status ALLOCID`. To view logs for each allocation, use `nomad alloc logs ALLOCID TASKNAME` and `nomad alloc logs -stderr ALLOCID TASKNAME`.

To remove jobs, you can run `nomad job stop -purge JOBID`. This will stop all instances of the job and remove logs for that jobs.

Files created by Nomad for each allocation can be found in `/var/local/nomad_data/alloc` or by using the `nomad alloc fs` interface.

