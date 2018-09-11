#!/bin/bash

#if [ ! "`whoami`" = root ]; then
#	echo "require root" 1>&2
#	exit 1
#fi

FTP_SERVERS=(ftp.jaist.ac.jp ftp.tsukuba.wide.ad.jp)
MAIL="test@example.com"
IMAGE="arch.iso"
LOOPDIR=$(mktemp -d)

if [ ! -s "$IMAGE" ]; then
	for FTP_SERVER in "$FTP_SERVERS"; do
		FNAME=$(ftp -n <<EOT | sed -ne '/\.iso$/p' | sed -e 's/^.* \([^ ]*\)$/\1/'
open $FTP_SERVER
user anonymous $MAIL
cd /pub/Linux/ArchLinux/iso/latest
ls
close
EOT
		)
		curl "ftp://$FTP_SERVER/pub/Linux/ArchLinux/iso/latest/$FNAME" -o "$IMAGE"
		if [ -s "$IMAGE" ]; then
			MD5SUM=$(curl "ftp://$FTP_SERVER/pub/Linux/ArchLinux/iso/latest/md5sums.txt" | sed -ne "/$FNAME/p" | awk '{print $1}')
			MD5SUM2=$(md5sum "$IMAGE" | awk '{print $1}')
			if [ "$MD5SUM" = "$MD5SUM2" ]; then
				break
			fi
		fi
		rm -f "$IMAGE"
	done
fi

if [ ! -s "$IMAGE" ]; then
	echo "image download error" 1>&2
	exit 1
fi

#mount -o loop "$IMAGE" "$LOOPDIR"
#cp -r setup-scripts "$LOOPDIR/root"
#umount "$LOOPDIR"

	
