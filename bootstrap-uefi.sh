#!/usr/bin/env bash
set -e

if [[ ! -v LOGFILE ]]; then
  export LOGFILE=$(mktemp -q)
  echo "== Using temporary logfile: ${LOGFILE}"
  (bash "${0}" "${@}") |& tee ${LOGFILE}
  exit ${?}
fi

function ask() {
  msg="?? ${1} "
  if [[ -v 2 ]]; then
    read -p "${msg}" ${2}
  else
    read -p "${msg}"
  fi
  echo
}

function confirm () {
  ask "${1} (y/N)"
  if [[ ${REPLY} =~ ^[Yy].* ]]; then
    return 0
  else
    return 1
  fi
}

function really_confirm () {
  ask "${1} (yes/NO)"
  echo "${REPLY}">>${LOGFILE}
  if [[ ! ${REPLY} =~ ^[Yy][Ee][Ss]$ ]]; then
    exit 1
  fi
}

function wait_for() {
  echo "-- Waiting for '${1}'..."
  while [[ ! -e ${1} ]]; do
    sleep 1
  done
}

function log() {
  echo "-- ${1}"
}

function die() {
  echo "!! ${1}"
  exit 1
}

FLAKE_REPO=${FLAKE_REPO:-https://github.com/thoughtfull-systems/nixos}

cat <<EOF
================================================================================
Begin installation $(date)

--------------------------------------------------------------------------------
This script will install NixOS into encrypted LVM volumes from the NixOS minimal
ISO.

You will be asked to provide the hostname, which will be used to select the
NixOS configuration from the flake.

You must create two partitions: an EFI system partition and a linux partition.

The EFI system partition should be named '\${HOST}-boot' and should be at least
1G in size.

The linux partition should be named '\${HOST}-lvm-crypt', and should be large
enough to include a swap (3x total memory, if supporting hibernation) and have
room for the installation, data, etc.

Other partitions may exist, and they will be left unmodified.

Current flake repository:

${FLAKE_REPO}

You can use a different git repository by defining FLAKE_REPO.
--------------------------------------------------------------------------------

EOF

really_confirm "Continue?"

ask "Please enter the hostname:" HOST
log "Using hostname: ${HOST}"

efi_device_name=${HOST}-boot
efi_device=/dev/disk/by-partlabel/${efi_device_name}

[[ -e ${efi_device} ]] ||
  die "EFI system partition '${efi_device}' does not exist"

log "Using EFI system partition: ${efi_device}"

if ! (sudo blkid |
        grep "PARTLABEL=\"${efi_device_name}\"" |
        grep "TYPE=\"vfat\"") &>/dev/null
then
  if confirm "'${efi_device}' is not a FAT filesytem, format it?"; then
    log "Formatting '${efi_device}' as a FAT filesystem"
    sudo mkfs.fat -F 32 -n BOOT --mbr=no ${efi_device}
  else
    exit 1
  fi
fi

lvm_device_name=${HOST}-lvm
lvm_device=/dev/mapper/${lvm_device_name}

lvm_crypt_device=/dev/disk/by-partlabel/${HOST}-lvm-crypt

[[ -e ${lvm_crypt_device} ]] ||
  die "Encrypted partition '${lvm_crypt_device}' does not exist"

log "Using encrytped partition: ${lvm_crypt_device}"

if [[ ! -e ${lvm_device} ]]; then
  if ! sudo cryptsetup isLuks ${lvm_crypt_device} &>/dev/null ||
      confirm "'${lvm_device}' is already a LUKS device, reformat?"; then
    log "Encrypting '${lvm_crypt_device}'..."
    really_confirm "Continue?"
    sudo cryptsetup luksFormat ${lvm_crypt_device}
  fi
  sudo cryptsetup open ${lvm_crypt_device} ${lvm_device_name}
  wait_for "${lvm_device}"
fi

log "Configuring LVM..."
if ! (sudo pvs | grep ${lvm_device}) &>/dev/null; then
  log "Creating '${lvm_device}' physical volume..."
  sudo pvcreate ${lvm_device}
fi
log "Using physical volume: ${lvm_device}"

vg_name=${HOST}
if ! (sudo vgs | grep ${vg_name}) &>/dev/null; then
  log "Creating '${vg_name}' volume group..."
  sudo vgcreate ${vg_name} ${lvm_device}
fi
log "Using volume group: ${vg_name}"

swap_volume=/dev/mapper/${vg_name}-swap
if ! (swapon | grep $(realpath ${swap_volume})) &>/dev/null; then
  if ! (sudo lvs -S "vg_name=${vg_name} && lv_name=swap" |
          grep swap) &>/dev/null
  then
    log "Creating 'swap' logical volume..."

    if confirm "Should 'swap' be large enough for hibertation?"; then
      swap_factor=3
    else
      swap_factor=2
    fi
    mem_total=$(($(grep MemTotal /proc/meminfo |\
                     grep -o [[:digit:]]\*)/1000000))
    swap_size=$((${mem_total}*${swap_factor}))
    log "Using swap size: ${swap_size}G"

    sudo lvcreate --size ${swap_size}G --name swap ${vg_name}
    wait_for "${swap_volume}"
    sudo mkswap -q -L swap ${swap_volume}
  fi
  sudo swapon ${swap_volume}
fi
log "Using swap logical volume: ${swap_volume}"

root_volume_name=${HOST}-root
root_volume=/dev/mapper/${root_volume_name}
if ! (sudo lvs -S "vg_name=${vg_name} && lv_name=root"|grep root)&>/dev/null
then
  log "Creating 'root' logical volume..."
  sudo lvcreate --extents 100%FREE --name root ${vg_name}
  wait_for "${root_volume}"
  sudo mkfs.ext4 -q -L root ${root_volume}
fi
log "Using root logical volume: ${root_volume}"

log "Mounting filesystems..."
if ! (mount -l | grep ${root_volume_name})&>/dev/null; then
  sudo mount ${root_volume} /mnt
  log "Mounted '${root_volume}' at '/mnt'"
fi

if ! (mount | grep $(realpath ${efi_device}))&>/dev/null; then
  sudo mkdir -p /mnt/boot/
  sudo mount ${efi_device} /mnt/boot
  log "Mounted '${efi_device}' at '/mnt/boot'"
fi

log "Installing git..."
nix-env -iA nixos.git

if [[ ! -e /mnt/etc/nixos ]]; then
  log "Initializing repository in '/mnt/etc/nixos/'..."
  sudo git clone ${FLAKE_REPO} /mnt/etc/nixos
fi

log "Swiching to '/mnt/etc/nixos/'"
cd /mnt/etc/nixos
log "Fetching latest..."
host_ref="origin/${HOST}"
sudo git fetch
if (sudo git branch -r --list ${host_ref} | grep ${host_ref}) &>/dev/null &&
     !(sudo git status | grep "On branch ${HOST}") &>/dev/null &&
     confirm "${HOST} branch found. Checkout?"
then
  log "Checking out: ${HOST}"
  sudo git checkout ${HOST}
fi

log "Generating configuration..."
sudo nixos-generate-config --root /mnt
sudo mv hardware-configuration.nix hosts/${HOST}/
log "Installing NixOS..."
really_confirm "Continue?" || exit 1
sudo nixos-install --no-root-password --flake .#${HOST}
cat <<EOF
== Finish installation $(date)
================================================================================
EOF
sudo bash -c "cat ${LOGFILE} >>/mnt/etc/nixos/hosts/${HOST}/install.log"
rm ${LOGFILE}
