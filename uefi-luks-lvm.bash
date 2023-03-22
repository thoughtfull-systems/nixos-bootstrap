#!/usr/bin/env bash

if [[ ! -v LOGFILE ]]; then
  export LOGFILE=$(mktemp -q)
  echo "== Setting up environment"
  echo "== Using temporary logfile: ${LOGFILE}"
  (nix --extra-experimental-features nix-command \
       --extra-experimental-features flakes \
       shell \
       nixpkgs#git \
       nixpkgs#age \
       nixpkgs#age-plugin-yubikey \
       nixpkgs#pcsclite-with-polkit \
       -c bash "${0}" "${@}") |& tee ${LOGFILE}
  exit ${?}
fi

# if this is done before the above subshell they get reset
set -euo pipefail

function ask() {
  msg="?? ${1} "
  if [[ -v 2 ]]; then
    read -p "${msg}" ${2}
  else
    read -p "${msg}"
  fi
  # in the log this separates lines between input, because input is not logged
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
  if [[ ! ${REPLY} =~ ^[Yy][Ee][Ss]$ ]]; then
    return 1
  fi
  return 0
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

function is_mounted() {
  (mount -l | grep ${1}) &>/dev/null
}

function is_fat32() {
  (sudo file -sL "${1}" | grep "FAT (32 bit)") &>/dev/null
}

function is_luks() {
  sudo cryptsetup isLuks "${1}" &>/dev/null
}

function is_swap() {
  (sudo swaplabel "${1}") &>/dev/null
}

function is_ext4() {
  (sudo file -sL "${1}" | grep "ext4 filesystem") &>/dev/null
}

host=${1:-$(hostname)}
flake_repo=${2:-https://github.com/thoughtfull-systems/nix-config}

cat <<EOF
================================================================================
Begin installation $(date)

--------------------------------------------------------------------------------
Usage:

  uefi-luks-lvm.bash [host] [flake repo]

This script will install NixOS into encrypted LVM volumes from the NixOS minimal
ISO.

You will be asked to provide the hostname, which will be used to select the
NixOS configuration from the flake.

You must create two partitions: an EFI system partition and a linux partition.

The EFI system partition should be named '\${host}-boot' and should be at least
1G in size.

The linux partition should be named '\${host}-lvm-crypt', and should be large
enough to include a swap (3x total memory, if supporting hibernation) and have
room for the installation, data, etc.

Other partitions may exist, and they will be left unmodified.

Current hostname:

  ${host}

You can use a different host by passing it as the first argument

Current flake git repository:

  ${flake_repo}

You can use a different git repository by passing it as the second argument.
--------------------------------------------------------------------------------

EOF

really_confirm "Continue?" || exit 1

efi_device_name=${host}-boot
efi_device=/dev/disk/by-partlabel/${efi_device_name}

[[ -e ${efi_device} ]] ||
  die "EFI system partition '${efi_device}' does not exist"

(sudo parted -l | grep ${efi_device_name} | grep "esp") &>/dev/null ||
  die "'${efi_device} is not an EFI system partition"

log "Using EFI system partition: ${efi_device}"

if ! is_fat32 ${efi_device} &&
    ! confirm "'${efi_device}' does not contain a FAT32 filesytem, format it?"
then
  die "'${efi_device}' must contain a FAT32 filesystem!"
elif ! is_fat32 ${efi_device} ||
    really_confirm "'${efi_device}' contains a FAT32 filesytem, re-format it?"
then
  log "Formatting '${efi_device}' as a FAT32 filesystem..."
  sudo mkfs.fat -F 32 -n BOOT --mbr=no ${efi_device}
fi

lvm_device_name=${host}-lvm
lvm_device=/dev/mapper/${lvm_device_name}
lvm_crypt_device=/dev/disk/by-partlabel/${host}-lvm-crypt

[[ -e ${lvm_crypt_device} ]] ||
  die "Encrypted partition '${lvm_crypt_device}' does not exist"

log "Using encrytped partition: ${lvm_crypt_device}"

if [[ ! -e ${lvm_device} ]]; then
  if ! is_luks ${lvm_crypt_device} &&
      ! confirm "'${lvm_crypt_device}' is not LUKS formatted, format it?"
  then
    die "'${lvm_crypt_device}' must be LUKS formatted!"
  elif ! is_luks ${lvm_crypt_device} ||
      really_confirm "'${lvm_crypt_device}' is LUKS formatted, re-format it?"
  then
    log "Encrypting '${lvm_crypt_device}'..."
    sudo cryptsetup luksFormat ${lvm_crypt_device}
  fi
  sudo cryptsetup open ${lvm_crypt_device} ${lvm_device_name}
  wait_for "${lvm_device}"
fi

log "Scanning for physical volumes..."
sudo pvscan
log "Scanning for volume groups..."
sudo vgscan
log "Scanning for logical volumes..."
sudo lvscan

log "Configuring LVM..."
if ! (sudo pvs | grep ${lvm_device}) &>/dev/null; then
  log "Creating '${lvm_device}' physical volume..."
  sudo pvcreate ${lvm_device}
fi
log "Using physical volume: ${lvm_device}"

vg_name=${host}
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
    log "Formatting '${swap_volume}' as a swap volume..."
    sudo mkswap -q -L swap ${swap_volume}
  elif ! is_swap ${swap_volume} &&
      ! confirm "'${swap_volume}' is not a swap volume, format it?"
  then
    die "${swap_volume} must be a swap volume!"
  elif ! is_swap ${swap_volume} ||
      really_confirm "'${swap_volume}' is a swap volume, re-format it?"
  then
    log "Formatting '${swap_volume}' as a swap volume..."
    sudo mkswap -q -L swap ${swap_volume}
  fi
  sudo swapon ${swap_volume}
fi
log "Using swap logical volume: ${swap_volume}"

root_volume_name=${host}-root
root_volume=/dev/mapper/${root_volume_name}

if ! (sudo lvs -S "vg_name=${vg_name} && lv_name=root" | grep root) &>/dev/null
then
  log "Creating 'root' logical volume..."
  sudo lvcreate --extents 100%FREE --name root ${vg_name}
  wait_for "${root_volume}"
  log "Formatting '${root_volume}' as an ext4 volume..."
  sudo mkfs.ext4 -q -L root ${root_volume}
elif ! is_ext4 ${root_volume} &&
    ! confirm "'${root_volume}' is not an ext4 volume, format it?"
then
  die "'${root_volume}' must be an ext4 volume!"
elif ! is_ext4 ${root_volume} ||
    really_confirm "'${root_volume}' is an ext4 volume, re-format it?"
then
  log "Formatting '${root_volume}' as an ext4 volume..."
  sudo mkfs.ext4 -q -L root ${root_volume}
fi
log "Using root logical volume: ${root_volume}"

log "Mounting filesystems..."
if ! is_mounted ${root_volume_name}; then
  log "Mounting'${root_volume}' at '/mnt'"
  sudo mount ${root_volume} /mnt
fi

if ! is_mounted $(realpath ${efi_device}); then
  sudo mkdir -p /mnt/boot/
  log "Mounting '${efi_device}' at '/mnt/boot'"
  sudo mount ${efi_device} /mnt/boot
fi

if [[ ! -e /mnt/etc/nixos ]]; then
  log "Initializing repository at '/mnt/etc/nixos'..."
  sudo git clone ${flake_repo} /mnt/etc/nixos
fi

log "Swiching to '/mnt/etc/nixos'"
cd /mnt/etc/nixos
log "Fetching latest..."
sudo git fetch

if (sudo git branch -r --list "origin/${host}" |
      grep "origin/${host}") &>/dev/null &&
     ! (sudo git status | grep "On branch ${host}") &>/dev/null &&
     confirm "${host} branch found. Checkout?"
then
  log "Checking out: ${host}"
  sudo git checkout ${host}
fi

log "Generating configuration..."
sudo nixos-generate-config --root /mnt
sudo mv hardware-configuration.nix hosts/${host}/
sudo git add hosts/${host}/hardware-configuration.nix
log "Installing NixOS..."
really_confirm "Continue?" || exit 1
sudo nixos-install --no-root-password --flake .#${host}

cat <<EOF
== Finish installation $(date)
================================================================================
EOF
sudo bash -c "cat ${LOGFILE} >>/mnt/etc/nixos/hosts/${host}/install.log"
rm ${LOGFILE}
