#!/bin/bash

set -x -e
kernel_version=`uname -r`

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
	which git || apt-get install git
	cd /usr/src
	git clone --depth 1 --single-branch --branch chromeos-${kernel_version:0:4} https://chromium.googlesource.com/chromiumos/third_party/kernel
}

build_kernel() {
	# Build Ubuntu kernel packages
	which make-kpkg || apt-get install kernel-package
	# This will fail on larger distros, as it requires mucho memory
	make-kpkg kernel_image kernel_headers
}

install_kernel() {
	KERNEL_DEBS=$1
	cd kernel

	# Create a kernel signing key
	mkdir -p /usr/share/vboot/devkeys
	# TODO

	# Configure the kernel
	cp ./chromeos/config/base.config ./chromeos/config/base.config.orig
	sed -e \
		's/CONFIG_SECURITY_CHROMIUMOS=y/CONFIG_SECURITY_CHROMIUMOS=n/' \
		./chromeos/config/base.config.orig > ./chromeos/config/base.config
	./chromeos/scripts/prepareconfig chromeos-intel-pineview
	yes "" | make oldconfig

	# Backup current kernel
	tstamp=$(date +%Y-%m-%d-%H%M)
	dd if=/dev/mmcblk0p6 of=../kernel-backup-$tstamp
	cp -Rp /lib/modules/`uname -r` /lib/modules/`uname -r`-backup-$tstamp

	# Install built kernel image/modules
	dpkg -i $KERNEL_DEBS

	# Extract old kernel config
	vbutil_kernel --verify /dev/mmcblk0p6 --verbose | tail -1 > ../config-$tstamp-orig.txt

	# Add permissions to a new config
	sed -e 's/$/ disablevmx=off/' \
		../config-$tstamp-orig.txt > ../config-$tstamp.txt

	# Repack the new kernel
	vbutil_kernel --pack ../newkernel \
		--keyblock /usr/share/vboot/devkeys/kernel.keyblock \
		--version 1 \
		--signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
		--config=../config-$tstamp.txt \
		--vmlinuz /boot/vmlinuz-`uname -r` \
		--arch x86_64

	# Verify the new kernel
	vbutil_kernel --verify /newkernel

	# Copy the new kernel to the ChrUbuntu partition
	dd if=../newkernel of=/dev/mmcblk0p6

	cd -
}

setup

if [ $1 == 'local' ]; then
	read -p "Installing kernel from source. This is a local build that will require mucho memory. Press enter to start..."
	build_kernel
	install_kernel /usr/src/linux-*.deb
else
	read -p "Installing kernel $1 (these should be linux-*.deb files). Press enter to start..."
	install_kernel $1
fi
