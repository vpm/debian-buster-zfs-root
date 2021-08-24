#!/bin/bash -e
#
# debian-buster-zfs-root.sh
#
# Install Debian GNU/Linux 10 Buster to a native ZFS root filesystem
#
#
# https://github.com/hn/debian-buster-zfs-root
# Installs Debian GNU/Linux 10 Buster to a native ZFS root filesystem using a Debian Live CD.
# The resulting system is a fully updateable debian system with no quirks or workarounds.
#
# https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Buster%20Root%20on%20ZFS.html
# Debian Buster Root on ZFS
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3.0 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
#

### Static settings, overridable by TARGET_* environment variables

PARTBIOS=${TARGET_PARTBIOS:-1}
PARTEFI=${TARGET_PARTEFI:-2}
PARTZFS=${TARGET_PARTZFS:-3}

NEWHOST=${TARGET_HOSTNAME}
NEWDNS=${TARGET_DNS:-8.8.8.8 8.8.4.4}

# check release
DEBRELEASE=$(head -n1 /etc/debian_version)
case $DEBRELEASE in
	11*)
		;;
	*)
		echo "Unsupported Debian Live CD release" >&2
		exit 1
		;;
esac

### User settings

declare -A BYID
while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l)

for DISK in $(lsblk -I8,254,259 -dn -o name); do
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
	fi
done

TMPFILE=$(mktemp)
whiptail --backtitle "$0" --title "Drive selection" --separate-output \
	--checklist "\nPlease select ZFS drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

while read -r DISK; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
		EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
	else
		DISKS+=("${BYID[$DISK]}")
		ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
		EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
	fi
done < "$TMPFILE"

whiptail --backtitle "$0" --title "RAID level selection" --separate-output \
	--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
	"RAID0" "Striped disks or single disk" off \
	"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
	"RAIDZ" "Distributed parity, one parity block" off \
	"RAIDZ2" "Distributed parity, two parity blocks" off \
	"RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

case "$RAIDLEVEL" in
  raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
  	;;
  raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
  	;;
  *)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
  	;;
esac

GRUBPKG=grub-pc
if [ -d /sys/firmware/efi ]; then
	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
		--menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
		"EFI" "Extensible Firmware Interface boot" \
		"BIOS" "Legacy BIOS boot" 2>"$TMPFILE"

	if [ $? -ne 0 ]; then
		exit 1
	fi
	if grep -qi EFI $TMPFILE; then
		GRUBPKG=grub-efi-amd64
	fi
fi

whiptail --backtitle "$0" --title "Confirmation" \
	--yesno "\nAre you sure to destroy ZFS pool 'rpool' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

if [ $? -ne 0 ]; then
	exit 1
fi

### Start the real work

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
	dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"

	sgdisk --zap-all $DISK

	sgdisk -a 4096 -n $PARTBIOS:0:+1M -t$PARTBIOS:EF02 \
	           -n$PARTEFI:0:+1G -t$PARTEFI:EF00 \
                   -n$PARTZFS:0:0 -t$PARTZFS:BF00 $DISK
done

# add contrib non-free and backports top apt lists
echo "deb http://deb.debian.org/debian bullseye contrib non-free" > /etc/apt/sources.list.d/bullseye-contrib-non-free.list

# 
export DEBIAN_FRONTEND=noninteractive

# install and build zfs kernel module
apt-get update && apt-get install --yes zfs-dkms debootstrap gdisk dosfstools

modprobe zfs

if [ $? -ne 0 ]; then
	echo "Unable to load ZFS kernel module" >&2
	exit 1
fi

apt-get install --yes zfsutils-linux

zpool create -f -o ashift=12 -O atime=off -O mountpoint=none rpool $RAIDDEF

if [ $? -ne 0 ]; then
	echo "Unable to create zpool 'rpool'" >&2
	exit 1
fi

# create root
zfs create -p -o mountpoint=/mnt rpool/ROOT/default
zfs create -o mountpoint=/mnt/tmp -o setuid=off -o devices=off rpool/tmp && chmod 1777 /mnt/tmp
zfs create -o mountpoint=/mnt/var rpool/var
zfs create rpool/var/tmp && chmod 1777 /mnt/var/tmp
zfs create rpool/var/log
zfs create rpool/var/lib
zfs create -V 2G -b "$(getconf PAGESIZE)" -o primarycache=metadata -o logbias=throughput -o sync=always rpool/swap

# sometimes needed to wait for /dev/zvol/rpool/swap to appear
sleep 3

mkswap -f /dev/zvol/rpool/swap

zpool status
zfs list

# Install base system
debootstrap --include=linux-headers-amd64,linux-image-amd64,openssh-server,locales,acpid,mc,nano,sudo,bash-completion,net-tools,lsof,console-setup --components main,contrib,non-free buster /mnt http://deb.debian.org/debian

test -n "$NEWHOST" || NEWHOST=debian-$(hostid)
echo "$NEWHOST" > /mnt/etc/hostname

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /mnt/etc/

cat << EOF > /mnt/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system>         <mount point>   <type>  <options>       <dump>  <pass>
/dev/zvol/rpool/swap     none            swap    defaults        0       0
EOF

mount -t proc /proc /mnt/proc
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev

ln -s /proc/mounts /mnt/etc/mtab

# set UTF-8 for console
sed -i s/'CHARMAP="ISO-8859-15"'/'CHARMAP="UTF-8"'/g /mnt/etc/default/console-setup

# set default locale
echo "LANG=ru_RU.UTF-8" > /mnt/etc/default/locale

# generate default locale
sed -i s/'# en_US.UTF-8 UTF-8'/'en_US.UTF-8 UTF-8'/g /mnt/etc/locale.gen
sed -i s/'# ru_RU.UTF-8 UTF-8'/'ru_RU.UTF-8 UTF-8'/g /mnt/etc/locale.gen
chroot /mnt locale-gen

chroot /mnt localedef -i en_US -f UTF-8 en_US.UTF-8
chroot /mnt localedef -i ru_RU -f UTF-8 ru_RU.UTF-8

echo "deb http://deb.debian.org/debian bullseye-updates main contrib non-free" >> /mnt/etc/apt/sources.list
echo "deb http://security.debian.org/debian-security bullseye-updates main contrib non-free" >> /mnt/etc/apt/sources.list

chroot /mnt apt-get update
chroot /mnt apt-get install --yes zfs-dkms zfsutils-linux grub2-common $GRUBPKG zfs-initramfs

echo REMAKE_INITRD=yes > /mnt/etc/dkms/zfs.conf

sed -i s/'GRUB_CMDLINE_LINUX=""'/'GRUB_CMDLINE_LINUX="boot=zfs"'/g /mnt/etc/default/grub

chroot /mnt update-grub

if [ "${GRUBPKG:0:8}" == "grub-efi" ]; then

	# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
	# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
	mkdir -pv /mnt/boot/efi
	I=0
	for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
		mkdosfs -F 32 -n EFI-$I $EFIPARTITION
		mount $EFIPARTITION /mnt/boot/efi
		chroot /mnt /usr/sbin/grub-install --target=x86_64-efi --no-uefi-secure-boot --efi-directory=/boot/efi --bootloader-id="Debian bullseye (RAID disk $I)" --recheck --no-floppy
		umount $EFIPARTITION
		if [ $I -gt 0 ]; then
			EFIBAKPART="#"
		fi
		echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /mnt/etc/fstab
		((I++)) || true
	done
fi

ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_ONBOARD=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_PATH=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=enp0s1
echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >> /mnt/etc/network/interfaces
for DNS in $NEWDNS; do
	echo -e "nameserver $DNS" >> /mnt/etc/resolv.conf
done

# disable password promt for users from group sudo
echo "%sudo ALL=(ALL:ALL) NOPASSWD:ALL" > /mnt/etc/sudoers.d/sudo

# set timezone to Europe/Kiev
chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Kiev /etc/localtime

# set root password
chroot /mnt passwd

# copy zpool.cache
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# delete symlinc for mtab 
unlink /mnt/etc/mtab

# umount dev, sys, proc
umount -Rf /mnt/dev
umount -Rf /mnt/sys
umount -Rf /mnt/proc

# set boot target
zpool set bootfs=rpool/ROOT/default rpool

# umount all zfs partitions
zfs umount -af

# set mountpoints
zfs set mountpoint=/ rpool/ROOT/default
zfs set mountpoint=/var rpool/var
zfs set mountpoint=/tmp rpool/tmp




