#!/bin/bash -E

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
	echo "loading $1 ..."
	source "$(pwd)/$1"
fi


: Install Start
if [ -z "$SECURE_ERASE" -o "$SECURE_ERASE" = "n" -o "$SECURE_ERASE" = false ]; then
	SECURE_ERASE=false
else
	SECURE_ERASE=true
fi
if [ -z "$ENCRYPT" -o "$ENCRYPT" = n -o "$ENCRYPT" = false ]; then
	ENCRYPT=false
else
	ENCRYPT=true
fi
export ENCRYPT
if [ -n "$BTRFS_OPTS" ]; then
	BTRFS_OPTS="$BTRFS_OPTS,"
fi
[ -z "$MOUNT_DIR" ] && MOUNT_DIR="/mnt"
if [ -z "$USER_NAME" ]; then
	echo "your name[yasuo]:"
	read USER_NAME
	[ -z "$USER_NAME" ] && USER_NAME=yasuo
fi
export USER_NAME
if [ -z "$PASSWORD" ]; then
	read -sp "Password:" PASSWORD
	echo ""
	if [ "$ENCRYPT" = true -a -z "$PASSWORD" ]; then
		echo "Password should be used to encrypt disk."
		exit 1
	fi
	read -sp "Password(again):" PASSWORD2
	echo ""
	if [ ! "$PASSWORD" = "$PASSWORD2" ]; then
		echo "Passwords mismatch"
		exit 1
	fi
fi
export PASSWORD

if [ -z "$NEW_HOSTNAME" ]; then
	HWNAME=`dmesg | sed -ne '/DMI/p' | sed -e 's/^.*DMI: \([^,.]*\).*$/\1/' | tr '/ ' '_'`
	if [ -z "$HWNAME" ]; then
		echo "input hostname:"
		read NEW_HOSTNAME
	else
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
	elif echo "$DISK" | grep -q "fd"; then
		echo "disk $DISK is floppy drive. ignore"
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
if [ "$DISKS_COUNT" -gt 1 ]; then
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

echo "target is $TARGET_DISK and $TARGET_DATA"

# HDD=1, SSD=0
TARGET_NAME=`echo "$TARGET_DISK" | sed -e 's/^.*\/\([^\/]*\)$/\1/'`
TARGET_NAME_DATA=`echo "$TARGET_DATA" | sed -e 's/^.*\/\([^\/]*\)$/\1/'`
IS_HDD=`cat /sys/block/$TARGET_NAME/queue/rotational`
IS_HDD_DATA=`cat /sys/block/$TARGET_NAME_DATA/queue/rotational`

if [ -z "$NOWAIT" ]; then
	echo "ALL DATA WILL BE DESTROYED. to stop, press Ctrl-C in 10 seconds."
	sleep 10
fi

echo "wiping fs..."

if [ "$SECURE_ERASE" = "true" ]; then
	echo "performing secure erase on system partition..."
	if [ "$IS_HDD" = "0" ] && blkdiscard -s "$TARGET_DISK"; then
		: success
	else
		: failed. try to overwrite
		shred -n 3 "$TARGET_DISK"
		[ "$IS_HDD" = "0" ] && blkdiscard "$TARGET_DISK"
	fi
	if [ ! "$TARGET_DATA" = "$TARGET_DISK" ]; then
		echo "performing secure erase on user partition..."
		if [ "$IS_HDD_DATA" = "0" ] && blkdiscard -s "$TARGET_DATA"; then
			: success
		else
			: failed. try to overwrite
			shred -n 3 "$TARGET_DATA"
			[ "$IS_HDD_DATA" = "0" ] && blkdiscard "$TARGET_DATA"
		fi
	fi
else
	echo "wiping system partition..."
	if [ "$IS_HDD" = "0" ] && echo "hello" &&  blkdiscard "$TARGET_DISK"; then
		:
	else
		wipefs "$TARGET_DISK"
	fi
	if [ ! "$TARGET_DATA" = "$TARGET_DISK" ]; then
		echo "wiping user partition..."
		if [ "$IS_HDD_DATA" = "0" ] && blkdiscard "$TARGET_DATA"; then
			:
		else
			wipefs "$TARGET_DATA"
		fi
	fi
fi

echo "creating partitions..."

MEMTOTAL=`cat /proc/meminfo | sed -ne '/^MemTotal:/p' | sed -e 's/^[^ ]* *\([0-9]*\) .*$/\1/'`
MEMTOTAL=`expr '(' '(' "$MEMTOTAL" - 1 ')' / 1048576 '+' 2 ')' '*' 1024`
if [ "$BOOTTYPE" = "legacy" ]; then
	# BIOS-MBR
	if [ "$ENCRYPT" = true ]; then
		# (grub) | boot partition (300MiB, ext4) | main partition | swap
		parted -s -a cylinder "$TARGET_DISK" -- mklabel msdos mkpart primary ext4 16384s 630784s mkpart primary btrfs 630785s -`expr "$MEMTOTAL" '+' 1` mkpart primary linux-swap -$MEMTOTAL 100% set 1 boot on
	else
		# (grub) | main partition | swap
		parted -s -a cylinder "$TARGET_DISK" -- mklabel msdos mkpart primary btrfs 16384s -`expr "$MEMTOTAL" '+' 1` mkpart primary linux-swap -$MEMTOTAL 100% set 1 boot on
	fi
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		parted -s -a cylinder "$TARGET_DATA" -- mklabel msdos mkpart primary btrfs 0 -0
	fi
else
	#UEFI-GPT
	# EFI System Partition | main partition | swap
	parted -s -a cylinder "$TARGET_DISK" ' mklabel gpt mkpart primary fat32 40s 393215s name 1 "EFI System Partition" mkpart primary btrfs 393216s -'`expr "$MEMTOTAL" '+' 1`' name 2 "Linux Filesystem" mkpart primary linux-swap -'$MEMTOTAL' 100% name 3 "Linux Swap" set 1 boot on set 1 esp on' || {
		echo "parted error"
		exit 1
	}
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		parted -s -a cylinder "$TARGET_DATA" ' mklabel gpt mkpart primary btrfs 40s 100% name 1 "Linux Filesystem"' || {
			echo "parted error"
			exit 1
		}
	fi
fi

if [ "$BOOTTYPE" = "efi" ]; then
	export PART_EFI=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/EFI System/p'|cut -f 1 -d ' '`
	if echo "$PART_EFI" | grep '/dev/' &> /dev/null; then
		echo "EFI partition is $PART_EFI"
	else
		echo "EFI partition not detected."
		exit 1
	fi
	export PART_LINUX=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/Linux filesystem/p'|cut -f 1 -d ' '`
	if echo "$PART_LINUX" | grep '/dev/' &> /dev/null; then
		echo "Linux partition is $PART_LINUX"
	else
		echo "Linux partition not detected."
		exit 1
	fi
	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		export PART_DATA=`fdisk -l -o Device,Type "$TARGET_DATA" | sed -ne '/Linux filesystem/p'|cut -f 1 -d ' '`
		if echo "$PART_DATA" | grep '/dev/' &> /dev/null; then
			echo "Data partition is $PART_DATA"
		else
			echo "Data partition not detected."
			exit 1
		fi
	fi
else
	if [ "$ENCRYPT" = true ]; then
		export PART_BOOT=`fdisk -l -o Device,Boot,Type "$TARGET_DISK" | sed -ne '/Linux$/p' | sed -ne '/\*/p' |cut -f 1 -d ' '`
		if echo "$PART_BOOT" | grep '/dev/' &> /dev/null; then
			echo "Boot partition is $PART_BOOT"
		else
			echo "Boot partition not detected. Maybe no boot flag?"
			exit 1
		fi
		export PART_LINUX=`fdisk -l -o Device,Boot,Type "$TARGET_DISK" | sed -ne '/Linux$/p' | sed -e '/\*/d' |cut -f 1 -d ' '`
	else
		export PART_LINUX=`fdisk -l -o Device,Boot,Type "$TARGET_DISK" | sed -ne '/Linux$/p' | sed -ne '/\*/p' |cut -f 1 -d ' '`
	fi
	if echo "$PART_LINUX" | grep '/dev/' &> /dev/null; then
		echo "Linux partition is $PART_LINUX"
	else
		echo "Linux partition not detected. Maybe no boot flag?"
		exit 1
	fi

	if [ ! "$TARGET_DISK" = "$TARGET_DATA" ]; then
		export PART_DATA=`fdisk -l -o Device,Boot,Type "$TARGET_DATA" | sed -ne '/Linux$/p' |cut -f 1 -d ' '`
		if echo "$PART_DATA" | grep '/dev/' &> /dev/null; then
			echo "Data partition is $PART_DATA"
		else
			echo "Data partition not detected."
			exit 1
		fi
	fi
fi
export PART_SWAP=`fdisk -l -o Device,Type "$TARGET_DISK" | sed -ne '/Linux swap/p'|cut -f 1 -d ' '`
if echo "$PART_SWAP" | grep '/dev/' &> /dev/null; then
	echo "Linux swap is $PART_SWAP"
else
	echo "Linux swap not detected."
	exit 1
fi

if [ "$ENCRYPT" = true ]; then
	/bin/echo -n "$PASSWORD" | cryptsetup luksFormat "$PART_LINUX" -
	/bin/echo -n "$PASSWORD" | cryptsetup open --allow-discards --type luks "$PART_LINUX" "part_linux" -
	export PART_LINUX_LOCKED="$PART_LINUX"
	export PART_LINUX="/dev/mapper/part_linux"
fi

if [ -n "$PART_BOOT" ]; then
	mkfs.ext4 "$PART_BOOT"
fi
if [ -n "$PART_EFI" ]; then
	mkfs.fat -F32 "$PART_EFI"
fi

IGNORE_LIST=("var/lib/systemd/coredump" "var/cache/pacman/pkg" "var/abs" "var/tmp" "srv")

mkfs.btrfs -L "Linux-System" "$PART_LINUX"

mount "$PART_LINUX" "$MOUNT_DIR"
cd "$MOUNT_DIR"
mkdir -p "root"
btrfs subvolume create "root/__active"
btrfs subvolume create "root/__snapshot"
for IGNORE_DIR in "$IGNORE_LIST"; do
	mkdir -p "root/__active/`dirname $IGNORE_DIR`"
	btrfs subvolume create "root/__active/$IGNORE_DIR"
done
if [ -z "$PART_DATA" ]; then
	mkdir -p "home"
	btrfs subvolume create "home/__snapshot"
	btrfs subvolume create "home/__active"
fi
cd /
umount "$MOUNT_DIR"

BTRFS_OPTS_BASE="$BTRFS_OPTS"
if [ "$IS_HDD" = "1" ]; then
	BTRFS_OPTS="${BTRFS_OPTS}noatime,autodefrag,compress=lzo,space_cache,"
else
	BTRFS_OPTS="${BTRFS_OPTS}noatime,compress=lzo,ssd,space_cache,"
fi
mount -o "${BTRFS_OPTS}subvol=root/__active" "$PART_LINUX" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot"
if [ -n "$PART_BOOT" ]; then
	mount "$PART_BOOT" "$MOUNT_DIR/boot"
elif [ -n "$PART_EFI" ]; then
	mount "$PART_EFI" "$MOUNT_DIR/boot"
fi
mkdir -p "$MOUNT_DIR/.snapshot"
mount -o "${BTRFS_OPTS}subvol=root/__snapshot" "$PART_LINUX" "$MOUNT_DIR/.snapshot"

if [ "$ENCRYPT" = true ]; then
	mkdir -p "$MOUNT_DIR/etc"
	dd bs=512 count=4 if=/dev/urandom of=$MOUNT_DIR/etc/keyfile
	cryptsetup luksFormat "$PART_SWAP" "$MOUNT_DIR/etc/keyfile"
	export PART_SWAP_LOCKED="$PART_SWAP"
	export PART_SWAP="/dev/mapper/part_swap"
	cryptsetup open --allow-discards --type luks --key-file "$MOUNT_DIR/etc/keyfile" "$PART_SWAP_LOCKED" "part_swap"
fi
mkswap "$PART_SWAP"

mkdir -p "$MOUNT_DIR/home"
if [ -z "$PART_DATA" ]; then
	mount -o "${BTRFS_OPTS}subvol=home/__active" "$PART_LINUX" "$MOUNT_DIR/home"
	mkdir -p "$MOUNT_DIR/home/.snapshot"
	mount -o "${BTRFS_OPTS}subvol=home/__snapshot" "$PART_LINUX" "$MOUNT_DIR/home/.snapshot"
else
	if [ "$ENCRYPT" = true ]; then
		cryptsetup luksFormat "$PART_DATA" "$MOUNT_DIR/etc/keyfile"
		export PART_DATA_LOCKED="$PART_DATA"
		export PART_DATA="/dev/mapper/part_data"
		cryptsetup open --allow-discards --type luks --key-file "$MOUNT_DIR/etc/keyfile" "$PART_DATA_LOCKED" "part_data"
	fi
	if [ -n "$PART_DATA" ]; then
		mkfs.btrfs -L "Linux-Data" "$PART_DATA"
	fi
	mount "$PART_DATA" "$MOUNT_DIR"
	cd "$MOUNT_DIR"
	mkdir -p "home"
	btrfs subvolume create "home/__active"
	btrfs subvolume create "home/__snapshot"
	cd /
	umount "$MOUNT_DIR"
	if [ "$IS_HDD_DATA" = "1" ]; then
		BTRFS_OPTS_DATA="${BTRFS_OPTS_BASE}noatime,autodefrag,compress=lzo,space_cache,"
	else
		BTRFS_OPTS_DATA="${BTRFS_OPTS_BASE}noatime,compress=lzo,ssd,space_cache,"
	fi
	mount -o "${BTRFS_OPTS_DATA}subvol=home/__active" "$PART_DATA" "$MOUNT_DIR/home"
	mkdir -p "$MOUNT_DIR/home/.snapshot"
	mount -o "${BTRFS_OPTS_DATA}subvol=home/__snapshot" "$PART_DATA" "$MOUNT_DIR/home/.snapshot"
fi

timedatectl set-ntp true

echo 'Server = http://ftp.jaist.ac.jp/pub/Linux/ArchLinux/$repo/os/$arch' > /etc/pacman.d/mirrorlist
echo 'Server = http://ftp.tsukuba.wide.ad.jp/Linux/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist
pacstrap "$MOUNT_DIR" base base-devel || {
	echo "pacstrap error"
	exit 1
}

if [ "$BOOTTYPE" = "efi" -o -n "$PART_BOOT" ]; then
	mount -o remount,ro "$MOUNT_DIR/boot"
fi
genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"
if [ "$BOOTTYPE" = "efi" -o -n "$PART_BOOT" ]; then
	mount -o remount,rw "$MOUNT_DIR/boot"
fi
sed -i -e '/swap/d' "$MOUNT_DIR/etc/fstab"
echo "$PART_SWAP	swap	swap	defaults	0	0" >> "$MOUNT_DIR/etc/fstab"

cp "$SCRIPT_DIR/stage02.sh" "$MOUNT_DIR/stage02.sh"
chmod +x "$MOUNT_DIR/stage02.sh"

if [ "$ENCRYPT" = true ]; then
	(
		useradd test
		cd "$SCRIPT_DIR/chkboot"
		sudo -u test makepkg -f
		CHKBOOT_FNAME=`find . -name "*.tar.xz"`
		cp "$CHKBOOT_FNAME" "$MOUNT_DIR/$CHKBOOT_FNAME"
		userdel test
	)
fi

cleaning() {
	rm "$MOUNT_DIR/stage02.sh"
	[ -n "$CHKBOOT_FNAME" ] && rm "$CHKBOOT_FNAME"
	if [ "$BOOTTYPE" = "efi" -o -n "$PART_BOOT" ]; then
		umount "$MOUNT_DIR/boot"
	fi
	umount "$MOUNT_DIR/home/.snapshot"
	umount "$MOUNT_DIR/home"
	umount "$MOUNT_DIR/.snapshot"
	umount "$MOUNT_DIR"
	[ -n "$PART_LINUX_LOCKED" ] && cryptsetup close "part_linux"
	[ -n "$PART_DATA_LOCKED" ] && cryptsetup close "part_data"
	[ -n "$PART_SWAP_LOCKED" ] && cryptsetup close "part_swap"
}

arch-chroot "$MOUNT_DIR" bash -c "/stage02.sh" || { 
	echo "chroot error"
	cleaning
	exit 1
}

cleaning

echo "install is finished."

exit 0
