#!/bin/sh

DEPS=(parted dhcpcd arch-chroot pacman pacstrap blkdiscard shred wipefs)

export LANG=C
SCRIPT_DIR=`cd \`dirname $0\`; pwd`

if [ ! "`whoami`" = "root" ]; then
	echo "script require root privilege."
	exit 1
fi

if cat /etc/os-release | grep "Arch Linux" &> /dev/null ; then
	:
else
	echo "this is not a distribution of Arch Linux."
	exit 1
fi

NOT_INSTALLED=
for DEP in "$DEPS"; do
	if which "$DEP" &> /dev/null; then
		:
	else
		NOT_INSTALLED=`echo "$NOT_INSTALLED$DEP"`
	fi
done
if [ ! -z "$NOT_INSTALLED" ]; then
	echo "command \"$NOT_INSTALLED\" is required, but not installed."
	exit 1
fi

echo "checking internet connection..."
I=0
while : ; do
	if curl www.waseda.jp &> /dev/null; then
		: ok
		break
	fi
	if [ "$I" -ge "3" ]; then
		echo "connection error. do you have valid ethernet connection?"
		echo "if you have no ethernet adapter, you can connect via wifi"
		echo "using \"wifi-menu\"."
		exit 1
	fi
	if ping -c 1 -w 1 www-proxy.waseda.jp &> /dev/null; then
		echo "setting Waseda proxy..."
		export all_proxy=http://www-proxy.waseda.jp:8080
	else
		I=`expr "$I" + 1`
		for DEV in `ip -o -br link show | sed -e 's/^\([^ ]*\) .*$/\1/'`; do
			echo $DEV
			if echo "$DEV" | grep -q "enp" &> /dev/null ; then
				if ip link show "$DEV" | grep -q "UP" &> /dev/null ; then :; else
					ip link set "$DEV" up
					sleep 1
					if ip link show "$DEV" | grep -q "UP" &> /dev/null ; then
						dhcpcd "/dev/$DEV"
						break
					fi
				fi
			fi
		done
	fi
done

if [ -f "$1" ]; then
	source "$1"
fi


: Install Start
if [ -z "$SECURE_ERASE" -o "$SECURE_ERASE" = "n" ]; then
	SECURE_ERASE=false
else
	SECURE_ERASE=true
fi
if [ -n "$BTRFS_OPTS" ]; then
	BTRFS_OPTS="$BTRFS_OPTS,"
fi
[ -z "$MOUNT_DIR" ] && MOUNT_DIR="/mnt"
if [ -z "$NEW_HOSTNAME" ]; then
	HWNAME=`dmesg | sed -ne '/DMI/p' | sed -e '/^.*DMI: \(.*\), BIOS .*$/\1/' | tr '/ ' '_'`
	if [ -z "$HWNAME" ]; then
		echo "input hostname:"
		read NEW_HOSTNAME
	else
		echo "your name[yasuo]:"
		read USER_NAME
		[ -z "$USER_NAME" ] && USER_NAME=yasuo
		echo "your PC name[$USER_NAME-$HWNAME]:"
		read NEW_HOSTNAME
		[ -z "$NEW_HOSTNAME" ] && NEW_HOSTNAME="$USER_NAME-$HWNAME"
	fi
fi
export NEW_HOSTNAME


loadkeys jp106

if [ ! -d "/sys/firmware/efi/efivars" ]; then
	export BOOTTYPE=legacy
	echo "legacy boot detected."
else
	export BOOTTYPE=efi
	echo "efi boot detected."
fi

MOUNTED=`mount | sed -e 's/^\([^ ]*\) on .*$/\1/'`
DISKS=
for DISK in `lsblk -nlp -o NAME,TYPE | awk '{if($2=="disk"||$2~/^raid/) print $1}' | tr '\n' ' '`; do
	if echo "$MOUNTED" | grep -q "$DISK"; then
		echo "disk $DISK is mounted. ignore"
	else
		if [ -z "$DISKS" ]; then DISKS="$DISK"
		else DISKS=`/bin/echo -e "${DISKS}\n$DISK"`
		fi
	fi
done

DISKS=`echo "$DISKS" | sort | uniq`
DISKS_COUNT=`echo "$DISKS" | wc -l`

echo "you have $DISKS_COUNT disks."

if [ -z "$DISKS" ]; then
	echo "no disk is available."
	echo "is the target device umounted?"
	exit 1
fi
if [ `echo "$DISKS" | wc -l` -gt 1 ]; then
	DISKS=`echo "$DISKS" | tr '\n' ' '`
	while : ; do
		echo "which disk will you use as a system partition($DISKS)?"
		read TARGET_DISK
		TARGET_DISK=`echo $TARGET_DISK | sed -e 's/ .*$//'`
		if [ ! "$TARGET_DISK" = "" ] &&  echo " $DISKS " | grep -q " $TARGET_DISK " > /dev/null; then
			break
		fi
		echo "Wrong input."
	done
	while : ; do
		echo "which disk will you use as a user partition($DISKS)[same]?"
		read TARGET_DATA
		TARGET_DATA=`echo $TARGET_DATA | sed -e 's/ .*$//'`
		[ -z "$TARGET_DATA" ] && TARGET_DATA="$TARGET_DISK"
		if echo " $DISKS " | grep -q " $TARGET_DISK " > /dev/null; then
			break
		fi
		echo "Wrong input."
	done
else
	TARGET_DISK="$DISKS"
	TARGET_DATA="$DISKS"
fi
export TARGET_DISK
export TARGET_DATA

# HDD=1, SSD=0
TARGET_NAME=`echo "$TARGET_DISK" | sed -e 's/^.*\/\([^\/]*\)$/\1/'`
TARGET_NAME_DATA=`echo "$TARGET_DATA" | sed -e 's/^.*\/\([^\/]*\)$/\1/'`
IS_HDD=`cat /sys/block/$TARGET_NAME/queue/rotational`
IS_HDD_DATA=`cat /sys/block/$TARGET_NAME_DATA/queue/rotational`

echo "disk $TARGET_DISK, $TARGET_DATA is selected."
echo "ALL DATA WILL BE DESTROYED. to stop, press Ctrl-C in 10 seconds."

sleep 10

if [ "$SECURE_ERASE" = "true" ]; then
	if [ "$IS_HDD" = "0" ] && blkdiscard -s "$TARGET_DISK"; then
		: success
	else
		: failed. try to overwrite
		shred -n 3 "$TARGET_DISK"
		[ "$IS_HDD" = "0" ] && blkdiscard "$TARGET_DISK"
	fi
	if [ ! "$TARGET_DATA" = "$TARGET_DISK" ]; then
		if [ "$IS_HDD_DATA" = "0" ] && blkdiscard -s "$TARGET_DATA"; then
			: success
		else
			: failed. try to overwrite
			shred -n 3 "$TARGET_DATA"
			[ "$IS_HDD_DATA" = "0" ] && blkdiscard "$TARGET_DATA"
		fi
	fi
else
	if [ "$IS_HDD" = "0" ] && blkdiscard "$TARGET_DISK"; then
		:
	else
		wipefs "$TARGET_DISK"
	fi
	if [ ! "$TARGET_DATA" = "$TARGET_DISK" ]; then
		if [ "$IS_HDD_DATA" = "0" ] && blkdiscard "$TARGET_DATA"; then
			:
		else
			wipefs "$TARGET_DATA"
		fi
	fi
fi

MEMTOTAL=`cat /proc/meminfo | sed -ne '/^MemTotal:/p' | sed -e 's/^[^ ]* *\([0-9]*\) .*$/\1/'`
MEMTOTAL=`expr '(' '(' "$MEMTOTAL" - 1 ')' / 1048576 '+' 1 ')' '*' 1024`
if [ "$BOOTTYPE" = "legacy" ]; then
	parted -s -a cylinder "$TARGET_DISK" -- mklabel msdos mkpart primary btrfs 16384s -`expr "$MEMTOTAL" '+' 1` mkpart primary linux-swap -$MEMTOTAL -0 set 1 boot on
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		parted -s -a cylinder "$TARGET_DATA" -- mklabel msdos mkpart primary btrfs 0 -0
	fi
else
	parted -s -a cylinder "$TARGET_DISK" -- mklabel gpt mkpart primary fat32 0 255 name 1 "EFI System Partition" mkpart primary btrfs 256 -`expr "$MEMTOTAL" '+' 1` name 2 "Linux Filesystem" mkpart primary linux-swap -$MEMTOTAL -0 name 3 "Linux Swap" set 1 boot on set 1 esp on
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		parted -s -a cylinder "$TARGET_DATA" -- mklabel gpt mkpart primary btrfs 0 -0 name 1 "Linux Filesystem"
	fi
fi

if [ "$BOOTTYPE" = "efi" ]; then
	PART_EFI=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/EFI System/p'|cut -f 1 -d ' '`
	if echo "$PART_EFI" | grep '/dev/' &> /dev/null; then
		echo "EFI partition is $PART_EFI"
	else
		echo "EFI partition not detected."
		continue
	fi
	PART_LINUX=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/Linux Filesystem/p'|cut -f 1 -d ' '`
	if echo "$PART_LINUX" | grep '/dev/' &> /dev/null; then
		echo "Linux partition is $PART_LINUX"
	else
		echo "Linux partition not detected."
		continue
	fi
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		PART_DATA=`fdisk -l -o Device,Type "$TARGET_DATA" | sed -ne '/Linux Filesystem/p'|cut -f 1 -d ' '`
		if echo "$PART_DATA" | grep '/dev/' &> /dev/null; then
			echo "Data partition is $PART_DATA"
		else
			echo "Data partition not detected."
			continue
		fi
	fi
else
	PART_LINUX=`fdisk -l -o Device,Boot,Type "$TARGET_DISK" | sed -ne '/Linux$/p' | sed -ne '/\*/p' |cut -f 1 -d ' '`
	if echo "$PART_LINUX" | grep '/dev/' &> /dev/null; then
		echo "Linux partition is $PART_LINUX"
	else
		echo "Linux partition not detected. Maybe no boot flag?"
		continue
	fi
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		PART_DATA=`fdisk -l -o Device,Boot,Type "$TARGET_DATA" | sed -ne '/Linux$/p' |cut -f 1 -d ' '`
		if echo "$PART_DATA" | grep '/dev/' &> /dev/null; then
			echo "Data partition is $PART_DATA"
		else
			echo "Data partition not detected."
			continue
		fi
	fi
fi
PART_SWAP=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/Linux swap/p'|cut -f 1 -d ' '`
if echo "$PART_SWAP" | grep '/dev/' &> /dev/null; then
	echo "Linux swap is $PART_SWAP"
else
	echo "Linux swap not detected."
	continue
fi
break

if [ -n "$PART_EFI" ]; then
	mkfs.fat -F32 "$PART_EFI"
fi
if [ -n "$PART_DATA" ]; then
	mkfs.btrfs -L "Linux-Data" "$PART_DATA"
fi

mkfs.btrfs -L "Linux-System" "$PART_LINUX"
mkswap "$PART_SWAP"

mount "$PART_LINUX" "$MOUNT_DIR"
cd "$MOUNT_DIR"
mkdir -p "root/__snapshot"
btrfs subvolume create "root/__active"
if [ -z "$PART_DATA" ]; then
	mkdir -p "home/__snapshot"
	btrfs subvolume create "home/__active"
fi
cd /
umount "$MOUNT_DIR"
if [ -n "$PART_DATA" ]; then
	mount "$PART_DATA" "$MOUNT_DIR"
	cd "$MOUNT_DIR"
	mkdir -p "home/__snapshot"
	btrfs subvolume create "home/__active"
	cd /
	umount "$MOUNT_DIR"
fi

BTRFS_OPTS_BASE="$BTRFS_OPTS"
if [ "$IS_HDD" = "1" ]; then
	BTRFS_OPTS="${BTRFS_OPTS}noatime,autodefrag,compress=lzo,space_cache,"
else
	BTRFS_OPTS="${BTRFS_OPTS}noatime,compress=lzo,ssd,space_cache,"
fi
mount -o "${BTRFS_OPTS}subvol=root/__active" "$PART_LINUX" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/home"
if [ -z "$PART_DATA" ]; then
	mount -o "${BTRFS_OPTS}subvol=home/__active" "$PART_LINUX" "$MOUNT_DIR/home"
else
	if [ "$IS_HDD_DATA" = "1" ]; then
		BTRFS_OPTS_DATA="${BTRFS_OPTS_BASE}noatime,autodefrag,compress=lzo,space_cache,"
	else
		BTRFS_OPTS_DATA="${BTRFS_OPTS_BASE}noatime,compress=lzo,ssd,space_cache,"
	fi
	mount -o "${BTRFS_OPTS_DATA}subvol=home/__active" "$PART_DATA" "$MOUNT_DIR/home"
fi

if [ "$BOOTTYPE" = "efi" ]; then
	mkdir -p "$MOUNT_DIR/boot"
	mount "$PART_EFI" "$MOUNT_DIR/boot"
fi

timedatectl set-ntp true

echo 'Server = http://ftp.jaist.ac.jp/pub/Linux/ArchLinux/$repo/os/$arch' > /etc/pacman.d/mirrorlist
echo 'Server = http://ftp.tsukuba.wide.ad.jp/Linux/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist
pacstrap "$MOUNT_DIR" base base-devel

if [ "$BOOTTYPE" = "efi" ]; then
	mount -o remount,ro "$MOUNT_DIR/boot"
fi
genfstab -U "$MOUNT_DIR" >> /mnt/etc/fstab
if [ "$BOOTTYPE" = "efi" ]; then
	mount -o remount,rw "$MOUNT_DIR/boot"
fi

cat "$SCRIPT_DIR/stage02.sh" | arch-chroot "$MOUNT_DIR"


echo "copying the scripts to your home..."

mkdir -p "$MOUNT_DIR/root/new-to-my-laptop"
cd "$SCRIPT_DIR"
cd ..
cp -rf ./* "$MOUNT_DIR/root/new-to-my-laptop/"

if [ "$BOOTTYPE" = "efi" ]; then
	umount "$MOUNT_DIR/boot"
fi
umount "$MOUNT_DIR/home"
umount "$MOUNT_DIR"

echo "install is finished."


