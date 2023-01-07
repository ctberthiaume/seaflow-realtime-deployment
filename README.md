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

Manually create a VirtualBox machine, installing Ubuntu 22.04 server.
Call it realtime-ship.

Export as OVA file.

```shell
# Find the VM name
VBoxManage list vms
# Export
VBoxManage export realtime-ship -o newvm.ova
```

## Import VMs on bare metal hosts

On the machine to be deployed

```shell
VBoxManage import realtime-ship.ova

# Note VM names
VBoxManage list vms
VBoxManage list runningvms
```

Import as the `realtime-instrument` VM as well if you'd like to test with a
simulated data producer.

## Set up the guest for static IP

If using bridged networking, you can change from DHCP to static IP.

Create a new file `/etc/netplan/01-static-adapter1.yaml` and add this text,
replacing network details as needed. If any other yaml files are present rename
them with a `.hide` or other extension.

```shell
network:
  ethernets:
    enp0s3:
      dhcp4: false
      addresses: [192.168.1.52/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1]
  version: 2
```

Then run

```shell
sudo netplan generate
sudo netplan try
sudo netplan apply
```

## Set up VirtualBox port forwarding for shore test VM

If the guest is set up with NAT networking, port forwarding will need to configured.
If using bridged networking this isn't necessary.

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

* add an SSH public key
* update the default user password
* turn off password SSH access
* disable root login.

Manually log in to the VM and add an SSH public key before running the `playbook-credentials.yml` Ansible playbook.

The `vault/secrets.yml` ansible-vault encrypted file should contain the `realtime_user_password` ansible variable.
If there should be separate passwords for each system use separate secrets files.

```shell
cd ansible

ansible-playbook -i inventories/realtime_ship.yml --ask-become-pass --ask-vault-pass \
  --extra-vars="@vault/secrets.yml" \
  playbook-credentials.yml

ansible-playbook -i inventories/realtime_shore.yml --ask-become-pass --ask-vault-pass \
  --extra-vars="@vault/secrets.yml" \
  playbook-credentials.yml
```

## Set up VirtualBox shared folders

Set a shared folders for the VMs. By default we'll place the `jobs_data` and
`cruisereplay_data` folders in the root of this repo.

Create it after the VM has been imported to Virtualbox with `VBoxManage`.
This location won't be automounted until we set that up later.

Important note: the virtualbox share name can't be the same as the folder mount
point in Ubuntu. I don't know why, but the folder wouldn't automount at boot
until I changed the name. I have no idea.
https://askubuntu.com/questions/1355061/shared-folder-was-not-found-vboxsf

First install virtualbox guest additions to support shared folders (vboxsf).

```shell
ansible-playbook -i inventories/realtime_ship.yml --ask-become-pass playbook-virtualbox-guest-additions.yml
ansible-playbook -i inventories/realtime_instrument.yml --ask-become-pass playbook-virtualbox-guest-additions.yml
```

Then create the directories, shutdown the VMs, add the shared folders to the VMs, and start them again.

```shell
[[ -d ../jobs_data ]] || mkdir ../jobs_data
VBoxManage controlvm realtime-ship acpipowerbutton
VBoxManage sharedfolder add realtime-ship --name jobsdata --hostpath=$(pwd)/../jobs_data
VBoxManage startvm --type headless realtime-ship

# To access cruise replay simulated data for testing on a separate VM
[[ -d ../cruisereplay_data ]] || mkdir ../cruisereplay_data
VBoxManage controlvm realtime-instrument acpipowerbutton
VBoxManage sharedfolder add realtime-instrument --name cruisereplaydata --hostpath=$(pwd)/cruisereplay_data
VBoxManage startvm --type headless realtime-instrument
```

Then configure the Linux automounts for the shared folders

```shell
ansible-playbook -i inventories/realtime-ship.yml --ask-become-pass playbook-mount-share-jobs-data.yml
ansible-playbook -i inventories/realtime-instrument.yml --ask-become-pass playbook-mount-share-cruisereplay-data.yml
```

## Provision software on ship and shore systems

```shell
# ship
ansible-playbook -i inventories/realtime-ship.yml --ask-become-pass playbook-realtime-ship.yml
# test instrument
ansible-playbook -i inventories/realtime-instrument.yml --ask-become-pass playbook-realtime-instrument.yml
# shore
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
