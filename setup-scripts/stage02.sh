
cd /
mv -r /root /home/root
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

if echo "$TARGET_DISK$TARGET_DATA" | grep -q "md" &> /dev/null; then
	sed -i -e 's/^\(HOOKS=.*\)\(filesystems.*\)$/\1mdadm_udev \2/' /etc/mkinitcpio.conf
	pacman --noconfirm -S mdadm
fi

pacman --noconfirm -S btrfs-progs

mkinitcpio -p linux

if [ "$BOOTTYPE" = "legacy" ]; then
	pacman --noconfirm -S grub
	grub-install --target=i386-pc "$TARGET_DISK"
	grub-mkconfig -o /boot/grub/grub.cfg
else
	bootctl install
	echo '[Trigger]' > /etc/pacman.d/hooks/systemd-boot.hook
	echo 'Type = Package' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo 'Operation = Upgrade' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo 'Target = systemd' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo '[Action]' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo 'Description = Updating systemd-boot' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo 'When = PostTransaction' >> /etc/pacman.d/hooks/systemd-boot.hook
	echo 'Exec = /usr/bin/bootctl update' >> /etc/pacman.d/hooks/systemd-boot.hook
fi

