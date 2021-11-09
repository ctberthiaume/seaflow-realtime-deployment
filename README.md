# seaflow-realtime-deployment

## Requirements

* Ansible 2.10+
* Public key SSH access with an admin sudo account on an Ubuntu 20.04 server that you wish to configure.

Since Ansible is a Python tool, the easiest way to install it is in a Python virtual environemnt. For example, using `pyenv` with the `pyenv-virtualenv` module

```shell
pyenv virtualenv ansible
pyenv activate ansible
pip install -U pip
pip install ansible passlib cryptography # passlib needed on MacOS for password hashing

# Now install galaxy collections
(cd ansible && ansible-galaxy install -r requirements.yml)
```

## Create shore (test) and ship, instrument (test) VM OVA files

```shell
cd packer/realtime-shore
packer init virtualbox-realtime-ship.pkr.hcl
packer build \
  -var ssh_private_key_file=<path-to-shore-private-key> \
  -var ssh_public_key_file=<path-to-shore-public-key> \
  virtualbox-realtime-ship.pkr.hcl

cd packer/realtime-ship
packer init virtualbox-realtime-ship.pkr.hcl
packer build \
  -var ssh_private_key_file=<path-to-ship-private-key> \
  -var ssh_public_key_file=<path-to-ship-public-key> \
  virtualbox-realtime-ship.pkr.hcl

# Build instrument test VM
packer init virtualbox-realtime-instrument.pkr.hcl
packer build \
  -var ssh_private_key_file=<path-to-ship-private-key> \
  -var ssh_public_key_file=<path-to-ship-public-key> \
  virtualbox-realtime-instrument.pkr.hcl
```

## Import VMs on bare metal hosts

From the repo root

```shell
VBoxManage import packer/realtime-ship/output-realtime-ship/*.ova
VBoxManage import packer/realtime-shore/output-realtime-shore/*.ova
VBoxManage import packer/realtime-instrument/output-realtime-instrument/*.ova

# Note VM names
VBoxManage list vms
VBoxManage list runningvms
```

## Set up VirtualBox shared folder

Set a shared folder for the realtime ship VM.
Because this configuration depends on the host filesystem it isn't added when the VM is created by Packer.
Create it after the VM has been imported to Virtualbox with `VBoxManage`.
This location won't be automounted until we set that up later.

Important note: the virtualbox share name can't be the same as the folder mount
point in Ubunut. I don't know why, but the folder wouldn't automount at boot
until I changed the name. I have no idea.
https://askubuntu.com/questions/1355061/shared-folder-was-not-found-vboxsf

```shell
VBoxManage sharedfolder add realtime-ship --name jobsdata --hostpath=$(pwd)/jobs_data
VBoxManage sharedfolder add realtime-instrument --name cruisereplaydata --hostpath=$(pwd)/cruisereplay_data
```

## Set up VirtualBox port forwarding for shore test VM

The guest will likely be run with NAT networking, in which case port forwarding will need to be set up.
Use `VBoxManage modifyvm --natpf1` for VMs which are stopped,
and `VBoxManage controlvm natpf1` for running vms.

In this example we forward guest port 80 to host port 3001.
The web server can be accessed on the host at `http://localhost:3001`.

Here's an example to expose all SSH and caddy reverse proxies on the guest machine

```shell
VBoxManage modifyvm realtime-shore --natpf1 "ssh,tcp,,2222,,22"
VBoxManage modifyvm realtime-shore --natpf1 "grafana,tcp,,3000,,80"
VBoxManage modifyvm realtime-shore --natpf1 "consul,tcp,,8800,,8800"
VBoxManage modifyvm realtime-shore --natpf1 "nomad,tcp,,4747,,4747"
VBoxManage modifyvm realtime-shore --natpf1 "minio,tcp,,4000,,4000"
VBoxManage modifyvm realtime-shore --natpf1 "fileserver,tcp,,5000,,5000"
```

## Create EC2 cloud shore instance

Manually for now, terraform eventually.

## Update SSh and ansible inventories

Update your `~/.ssh/config` to configure SSH access to each machine,
and update ansible inventory files to use these host name aliases.

* inventories/realtime_ship.yml
* inventories/realtime_shore.yml

## Update credentials on ship or shore system

Update the default user password, turn off password SSH access, disable root login.

The secrets.yml ansible-vault encrypted file should contain the `realtime_user_password` ansible variable.
If there should be separate passwords for each system use separate secrets files.

```shell
cd ansible

ansible-playbook -i inventories/realtime_ship.yml --ask-vault-pass \
  --extra-vars="@vault/secrets.yml" \
  playbook-credentials.yml

ansible-playbook -i inventories/realtime_shore.yml --ask-vault-pass \
  --extra-vars="@vault/secrets.yml" \
  playbook-credentials.yml
```

## Provision software on ship and shore systems

```shell
cd ansible

# Set up the shared folder mount on the realtime ship VM
ansible-playbook -i inventories/realtime-ship.yml playbook-mount-share-jobs-data.yml
# Full provisioning
ansible-playbook -i inventories/realtime-ship.yml playbook-realtime-ship.yml

# Set up the shared folder mount on the realtime instrument VM
ansible-playbook -i inventories/realtime-instrument.yml playbook-mount-share-cruisereplay-data.yml
# Full provisioning
ansible-playbook -i inventories/realtime-instrument.yml playbook-realtime-instrument.yml


ansible-playbook -i inventories/realtime-shore.yml playbook-realtime-shore.yml
```

## Update consul key value configs

Copy and modify `consul_state/consul_state_ship_example.json` and `consul_state/consul_state_shore_example.json`.
Then copy to the appropriate server and import the file.
Assume we have SSH config aliases set up for these machines.

```shell
# Make new copies of example files
cp consul_state/consul_state_ship_example.json consul_state/consul_state_ship.json
cp consul_state/consul_state_shore_example.json consul_state/consul_state_shore.json

# Edit JSON files

# Copy to hosts
scp consul_state/consul_state_ship.json realtime-ship:/etc/realtime/consul_state.json
scp consul_state/consul_state_shore.json realtime-shore:/etc/realtime/consul_state.json

ssh realtime-ship
# Back up the current consul state
realtime-ship:~$ consul kv export | jq '[ .[] | .value = (.value | @base64d) ]' > /etc/realtime/consul_state_$(date --rfc-3339=seconds | awk '{print $1 "T" $2}').json
# Load key value data
realtime-ship:~$ jq '[ .[] | .value = (.value | @base64) ]' < /etc/realtime/consul_state.json | consul kv import -

# Do the same for realtime-shore
# ...
```

## vagrant variation usage

Same as with a normal virtualbox VM except you have to specify an alternative
realtime user. e.g.

```shell
ansible-playbook -i ansible/inventories/vagrant.yml  -l sink --extra-vars "realtime_user=vagrant" ansible/playbook-sink.yml
```

## Add popcycle sqlite3 database file to consul JSON

For the popcycle Sqlite3 database, add it as a base64 encoded gzip string.
Use this shell snippet to construct the correct JSON object for the database data.
The base64 string should be around 30K in size for one set of gates.

```shell
cp mydb.db clean.db
# Delete unneeded data
sqlite3 clean.db 'delete from vct; delete from opp; delete from outlier; delete from sfl; vacuum;'
# Make sure metadata table has correct cruise and instrument serial
# ...
printf "{\n    \"key\": \"seaflow-analysis/740/dbgz\",\n    \"value\": \"$(gzip -c clean.db | base64 -w 0)\"\n}\n"
```

## Add a string with newlines to consul JSON

JSON strings can't contain newline characters. They must be escaped as "\\n".
Use this blurb to encode such a strings.

```shell
cat textfile | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\n", "\\\\n"))'
```

And this one to decode "\n" once the JSON value is retrieved (e.g. with consul key get)

```shell
consul key get string-with-newlines | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n", "\n"))'
```

## Useful VBoxManage commands

```sh
VBoxManage list vms
VBoxManage list runningvms
VBoxManage import <file.ova>
VBoxManage startvm --type headless <vm-name>
VBoxManage controlvm <vm-name> poweroff|savestate|acpipowerbutton|reset
VBoxManage unregistervm <vm-name>  # remove stopped vm
VBoxManage modifyvm <vm-name> --memory 22528
VBoxManage modifyvm <vm-name> --cpus 3
VBoxManage modifyvm <vm-name> --macaddress1 080027BF7D02
```
