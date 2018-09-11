#!/bin/bash

TMPDIR=$(mktemp -d)
DISKIMAGE_ROOT="$TMPDIR/image_root.cow"
DISKIMAGE_USER="$TMPDIR/image_user.cow"
INSTALL_MEDIA=arch.iso

TAB="	"

rm -f "$DISKIMAGE_ROOT" "$DISKIMAGE_USER"
qemu-img create -f qcow2 "$DISKIMAGE_ROOT" 8G

echo "Running emulator..."
#qemu-system-x86_64 -m 1024 -cdrom "$INSTALL_MEDIA" -virtfs local,id=ntml,path=.,security_model=none,mount_tag=ntml -boot order=c -drive file=$DISKIMAGE_ROOT,format=qcow2 -nographic -serial mon:stdio <<EOT > log.txt
#$TAB console=ttyS0,38400
#root
#EOT
expect -c "
set timeout 600
spawn qemu-system-x86_64 -m 1024 -cdrom $INSTALL_MEDIA -virtfs local,id=ntml,path=.,security_model=none,mount_tag=ntml -boot order=c -drive file=$DISKIMAGE_ROOT,format=qcow2 -nographic -serial mon:stdio
expect \"Boot Arch Linux (x86_64)\"
send \"$TAB\"
expect \"boot/x86_64/archiso.img\"
send \" console=ttyS0,38400\\n\"
expect \"archiso login:\"
send \"root\\n\"
sleep 1
expect \"#\"
send \"mkdir /root/ntml\\n\"
sleep 1
expect \"#\"
send \"mount -t 9p -o trans=virtio ntml /root/ntml -oversion=9p2000.L\\n\"
sleep 1
expect \"#\"
send \"cd /root/ntml\\n\"
sleep 1
expect \"#\"
send \"./setup-scripts/stage01.sh test_config.conf || echo ERROR   DETECTED\\n\"
sleep 1
expect {
	\"#\" {
		exp_continue
	}
	\"ERROR DETECTED\" {
		exit 1
	}
}
send \"poweroff\\n\"
sleep 1
expect \"Power down\"
sleep 2
wait
exit 0
" | tr -d '\000\033'
echo "return: $?"
#> log.txt

