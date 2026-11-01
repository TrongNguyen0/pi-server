#!/usr/bin/env bash
# One-time setup of a fresh Raspberry Pi OS Lite (64-bit) on the SD card. Safe to re-run.
#   First run:  sudo bash bootstrap.sh /dev/sda   (the USB SSD, will be ERASED after you confirm)
#   Re-run:     sudo bash bootstrap.sh            (SSD already mounted on /srv)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
user=${SUDO_USER:?run via sudo from your normal user, not as root}
home=$(getent passwd "$user" | cut -d: -f6)
ssd=${1:-}

# Password login gets disabled below; without a key you would lock yourself out.
[[ -s $home/.ssh/authorized_keys ]] || {
	echo "no SSH key for $user yet. From your PC run: ssh-copy-id $user@<pi-ip>" >&2
	exit 1
}

apt-get update
apt-get -y full-upgrade
apt-get -y install ufw unattended-upgrades samba parted curl

# --- USB SSD -> /srv -------------------------------------------------------------------
if ! mountpoint -q /srv; then
	[[ -b $ssd ]] || { echo "SSD not mounted on /srv. Pass the disk, e.g.: sudo bash bootstrap.sh /dev/sda" >&2; lsblk -d -o NAME,SIZE,MODEL,TRAN; exit 1; }
	[[ $(lsblk -dno TYPE "$ssd") == disk ]] || { echo "$ssd is not a whole disk" >&2; exit 1; }
	# Refuses the SD card (it has mounted partitions) and any disk in use.
	if lsblk -no MOUNTPOINTS "$ssd" | grep -q .; then echo "$ssd has mounted partitions, refusing" >&2; exit 1; fi
	lsblk -o NAME,SIZE,MODEL,TRAN "$ssd"
	read -rp "ERASE everything on $ssd? Type YES: " ok
	[[ $ok == YES ]] || exit 1
	wipefs -a "$ssd"
	parted -s "$ssd" mklabel gpt mkpart data ext4 0% 100%
	udevadm settle
	part=$(lsblk -nrpo NAME "$ssd" | sed -n 2p)
	mkfs.ext4 -F -L pi-data "$part"
	uuid=$(blkid -s UUID -o value "$part")
	# nofail: the Pi still boots without the SSD (Docker then waits, see below).
	echo "UUID=$uuid /srv ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2" >> /etc/fstab
	systemctl daemon-reload
	mount /srv
fi
mkdir -p /srv/docker /srv/personal
chown "$user:$user" /srv /srv/personal

# Keep the SD card for the OS only: cap the system journal.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=100M\n' > /etc/systemd/journald.conf.d/10-size.conf
systemctl restart systemd-journald

# --- SSH: keys only, no root -----------------------------------------------------------
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sshd -t
systemctl reload ssh

# --- Firewall: nothing inbound except SSH/Samba from the local network, and Tailscale ----
# Public traffic needs no open port: cloudflared dials out.
ufw default deny incoming
ufw default allow outgoing
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
	ufw allow from "$net" to any port 22 proto tcp
	ufw allow from "$net" to any port 445 proto tcp
done
ufw allow in on tailscale0
ufw --force enable

# --- Automatic security updates --------------------------------------------------------
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- Docker: data on the SSD, rotated logs ---------------------------------------------
mkdir -p /etc/docker /etc/systemd/system/docker.service.d
echo '{"data-root": "/srv/docker", "log-driver": "local"}' > /etc/docker/daemon.json
# Without the SSD Docker must not start, or it would silently write to the SD card.
printf '[Unit]\nRequiresMountsFor=/srv\n' > /etc/systemd/system/docker.service.d/10-srv.conf
systemctl daemon-reload
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
systemctl restart docker
# Members of the docker group are effectively root: add only yourself.
usermod -aG docker "$user"

# --- Samba: /srv/personal as a network drive (\\<pi>\personal) ---------------------------
if ! grep -q '^\[personal\]' /etc/samba/smb.conf; then
	cat >> /etc/samba/smb.conf <<EOF

[personal]
   path = /srv/personal
   valid users = $user
   read only = no
   browseable = yes
   create mask = 0644
   directory mask = 0755
EOF
fi
grep -q 'server min protocol = SMB3' /etc/samba/smb.conf \
	|| sed -i 's/^\[global\]$/[global]\n   server min protocol = SMB3/' /etc/samba/smb.conf
pdbedit -L | grep -q "^$user:" || { echo "Set the Samba password for $user:"; smbpasswd -a "$user"; }
systemctl disable --now nmbd 2>/dev/null || true
systemctl restart smbd

# --- Tailscale: private access to SSH, Samba, Portainer, Dozzle -------------------------
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
tailscale status >/dev/null 2>&1 || tailscale up
tailscale serve --bg --http=9000 http://127.0.0.1:9000   # Portainer
tailscale serve --bg --http=8081 http://127.0.0.1:8081   # Dozzle

ip=$(tailscale ip -4 2>/dev/null | head -n 1)
cat <<EOF

done. Next:
  1. log out and back in (docker group)
  2. mv ~/pi-server /srv/ && cd /srv/pi-server && ./pi core
  3. within 5 minutes open http://$ip:9000 and create the Portainer admin
     logs: http://$ip:8081   files: \\\\$ip\\personal
EOF
