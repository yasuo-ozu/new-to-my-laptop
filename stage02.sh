sleep 10

cd /
mv /root /home/root
ln -snf /home/root /

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime

hwclock --systohc --utc

locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo KEYMAP=jp106 > /etc/vconsole.conf

echo "$NEW_HOSTNAME" > /etc/hostname
echo '127.0.0.1	localhost' > /etc/hosts
echo '::1		localhost' >> /etc/hosts
echo "127.0.1.1	$NEW_HOSTNAME.localdomain	$NEW_HOSTNAME" >> /etc/hosts

# hooks resume mdadm
sed -i -e 's/^\(HOOKS=.*filesystems\)\(.*\)$/\1 resume\2/' /etc/mkinitcpio.conf
[ "$ENCRYPT" = true ] && sed -i -e 's/^\(HOOKS=.*block\)\(.*\)$/\1 keymap encrypt openswap\2/' /etc/mkinitcpio.conf

if echo "$TARGET_DISK$TARGET_DATA" | grep -q "md" &> /dev/null; then
	sed -i -e 's/^\(HOOKS=.*\)\(filesystems.*\)$/\1mdadm_udev \2/' /etc/mkinitcpio.conf
	pacman --noconfirm -S mdadm
fi


if [ "$ENCRYPT" = true ]; then
	mkdir -p "/etc/initcpio/hooks"
	mkdir -p "/etc/initcpio/install"
	cat > "/etc/initcpio/hooks/openswap" <<EOT
run_hook()
{
	x=0;
	while [ ! -b /dev/mapper/part_linux ] && [ $x -le 10 ]; do
	   x=$((x+1))
	   sleep .2
	done
	mkdir crypto_key_device
	mount /dev/mapper/part_linux crypto_key_device -o subvol=root/__active
	cryptsetup open --allow-discards --type luks --key-file crypto_key_device/etc/keyfile "$PART_SWAP_LOCKED" "part_swap"
	umount crypto_key_device
}
EOT
	cat > "/etc/initcpio/install/openswap" <<EOT
build ()
{
   add_runscript
}
help ()
{
cat<<HELPEOF
  This opens the swap encrypted partition /dev/<device> in /dev/mapper/swapDevice
HELPEOF
}
EOT
	
	CHKBOOT_FNAME=`find / -name "*.tar.xz"`
	pacman -U "$CHKBOOT_FNAME"
	systemctl enable chkboot
fi
echo "before pacman"
sleep 10
pacman --noconfirm -S btrfs-progs
echo "after pacman"
sleep 10
mkinitcpio -p linux

if [ "$BOOTTYPE" = "legacy" ]; then
	UUID_LINUX=`lsblk -o NAME,UUID "PART_LINUX" | tail -n 1 | cut -d " " -f2`
	UUID_SWAP=`lsblk -o NAME,UUID "PART_SWAP" | tail -n 1 | cut -d " " -f2`
	pacman --noconfirm -S grub
	grub-install --target=i386-pc "$TARGET_DISK"
	grub-mkconfig -o /boot/grub/grub.cfg
	sed -i -e 's/^\(GRUB_CMDLINE_LINUX=".*\)\("\)$/\1 resume=UUID='"$UUID_SWAP"'\2/' /etc/default/grub
	if [ "$ENCRYPT" = true ]; then
		sed -i -e 's/^\(GRUB_CMDLINE_LINUX=".*\)\("\)$/\1 cryptdevice='"$PART_LINUX_LOCKED"':part_linux:allow-discards\2/' /etc/default/grub
	fi
	grub-setup "$TARGET_DISK"
else
	bootctl install
	mkdir -p /etc/pacman.d/hooks
	cat > /etc/pacman.d/hooks/systemd-boot.hook <<EOT
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd
[Action]
Description = Updating systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
EOT
	cat > /boot/loader/loader.conf <<EOT
default	arch
timeout	4
editor	no
EOT
	[ -n "$PART_LINUX_LOCKED" ] &&  PARTUUID_LINUX_LOCKED=`blkid "$PART_LINUX_LOCKED" | sed -e 's/^.*PARTUUID="\([^"]*\)"$/\1/'`
	[ -n "$PART_DATA_LOCKED" ] &&  PARTUUID_DATA_LOCKED=`blkid "$PART_DATA_LOCKED" | sed -e 's/^.*PARTUUID="\([^"]*\)"$/\1/'`
	[ -n "$PART_SWAP_LOCKED" ] &&  PARTUUID_SWAP_LOCKED=`blkid "$PART_SWAP_LOCKED" | sed -e 's/^.*PARTUUID="\([^"]*\)"$/\1/'`
	mkdir -p /boot/loader/entries
	cat > /boot/loader/entries/arch.conf <<EOT
title	Arch Linux
linux	/vmlinuz-linux
initrd	/initramfs-linux.img
options	root=$PART_LINUX rw rootflags=subvol=root/__active resume=$PART_SWAP
EOT
	if [ "$ENCRYPT" = true ]; then
		sed -i -e 's/^options.*$/\0 cryptdevice=PARTUUID='$PARTUUID_LINUX_LOCKED':part_linux:allow-discards/' /boot/loader/entries/arch.conf
		cat > "$MOUNT_DIR/etc/crypttab" <<EOT
part_linux	PARTUUID=$PARTUUID_LINUX_LOCKED	none	luks,timeout=180
part_swap	PARTUUID=$PARTUUID_SWAP_LOCKED	/etc/keyfile	luks,timeout=180
EOT
		if [ -n "$PARTUUID_DATA_LOCKED" ]; then
			echo "part_data	PARTUUID=$PARTUUID_DATA_LOCKED	/etc/keyfile	luks,timeout=180" >> /etc/crypttab
		fi
	fi
fi

useradd -G wheel -m "$USER_NAME"
/bin/echo -n "$USER_NAME:$PASSWORD" | chpasswd
/bin/echo -n "root:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

