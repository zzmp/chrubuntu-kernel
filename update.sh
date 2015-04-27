#!/bin/bash

set -x -e
kernel_version=`uname -r`
target=${1:-fake}

setup() {
	# Grab verified boot utilities from ChromeOS
	mkdir -p /usr/share/vboot
	mount -o ro /dev/mmcblk0p3 /mnt
	cp /mnt/usr/bin/vbutil_* /usr/bin
	cp /mnt/usr/bin/dump_kernel_config /usr/bin
	rsync -avz /mnt/usr/share/vboot/ /usr/share/vboot/
	umount /mnt

	# ChromeOS may be a 32-bit target, so apt-get the
	# 32-bit .so's for the boot binaries to link against
	# apt-get install libc6:i386 libssl1.0.0:i386

	# Fetch ChromeOS kernel sources
	if [ ! -d /usr/src/kernel ]; then
		read -p "Fetching the kernel source. Press any key to continue..."
		which git || apt-get install git
		cd /usr/src
		git clone --depth 1 --single-branch --branch chromeos-${kernel_version:0:4} https://chromium.googlesource.com/chromiumos/third_party/kernel
		cd -
	fi
}

build_kernel() {
	cd /usr/src/kernel

	# Build Ubuntu kernel packages
	which make-kpkg || apt-get install kernel-package
	# This will fail on larger distros, as it requires mucho memory
	make-kpkg kernel_image kernel_headers

	cd -
}

install_kernel() {
	DIR=`pwd`
	cd /usr/src/kernel

	# Configure the kernel
	cp ./chromeos/config/base.config ./chromeos/config/base.config.orig
	sed -e \
		's/CONFIG_SECURITY_CHROMIUMOS=y/CONFIG_SECURITY_CHROMIUMOS=n/' \
		./chromeos/config/base.config.orig > ./chromeos/config/base.config
	./chromeos/scripts/prepareconfig chromeos-intel-pineview
	yes "" | make oldconfig

	# Backup current kernel
	tstamp=$(date +%Y-%m-%d-%H%M)
	dd if=/dev/mmcblk0p6 of=$DIR/kernel-backup-$tstamp
	mv /lib/modules/`uname -r` /lib/modules/`uname -r`-backup-$tstamp

	# Install built kernel image/modules
	read -p "Installing kernel modules. Press any key to continue..."
	dpkg -i $DIR/kernel/$target/linux-*.deb

	# Extract old kernel config
	vbutil_kernel --verify /dev/mmcblk0p6 --verbose | tail -1 > $DIR/config-$tstamp-orig.txt

	# Add permissions to a new config
	sed -e 's/$/ disablevmx=off/' \
		$DIR/config-$tstamp-orig.txt > $DIR/config-$tstamp.txt

	# Repack the new kernel
	vbutil_kernel --pack $DIR/repacked_kernel \
		--keyblock /usr/share/vboot/devkeys/kernel.keyblock \
		--version 1 \
		--signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
		--config=$DIR/config-$tstamp.txt \
		--vmlinuz /boot/vmlinuz-`uname -r` \
		--arch x86_64

	# Verify the new kernel
	vbutil_kernel --verify $DIR/repacked_kernel

	# Copy the new kernel to the ChrUbuntu partition
	read -p "Copying in the repacked kernel. Press any key to continue..."
	dd if=$DIR/repacked_kernel of=/dev/mmcblk0p6

	cd -
}

setup

if [ $target == 'local' ]; then
	read -p "Repacking kernel from source. This is a local build that will require mucho memory. Press any key to start..."
	build_kernel
	install_kernel /usr/src/linux-*.deb
elif [ -d ./kernel/$target ]; then
	read -p "Repacking kernel from cached version $target. Press any key to start..."
	install_kernel $target
else
	echo "You must specify a valid version to build."
	exit 1
fi
