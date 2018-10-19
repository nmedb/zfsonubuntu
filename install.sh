export TARGET_HOSTNAME="hostname"
export NETWORK_INTERFACE=eth0
export DISK=/dev/
export PART1=${DISK}1
export PART2=${DISK}2
export PART3=${DISK}3
export DIST_CODENAME=$(lsb_release -sc)
export ZPOOL=rpool

#----------------------------------------------------------------------------------------------------

apt install --yes zfsutils-linux cryptsetup debootstrap dosfstools gdisk

sgdisk -o $DISK
sgdisk -n1:1M:+512M -t1:8300 $DISK
sgdisk -n2:0:+256M -t2:EF00 $DISK
sgdisk -n9:-8M:0 -t9:BF07 $DISK
sgdisk -n3:0:0 -t3:8300 $DISK

cryptsetup luksFormat -c aes-xts-plain64 -s 512 -h sha512 ${PART3}
# prompt

cryptsetup luksOpen ${PART3} ${ZPOOL}_crypt
# prompt

zpool create -o ashift=12 -O atime=off -O canmount=off -O compression=lz4 -O normalization=formD -O mountpoint=/ -R /mnt $ZPOOL /dev/mapper/${ZPOOL}_crypt
zfs create -o canmount=off -o mountpoint=none ${ZPOOL}/ROOT
zfs create -o canmount=noauto -o mountpoint=/ ${ZPOOL}/ROOT/ubuntu
zfs mount ${ZPOOL}/ROOT/ubuntu
zfs create -o setuid=off ${ZPOOL}/home
zfs create -o mountpoint=/root ${ZPOOL}/home/root
zfs create -o canmount=off -o setuid=off -o exec=off ${ZPOOL}/var
zfs create -o com.sun:auto-snapshot=false ${ZPOOL}/var/cache
zfs create ${ZPOOL}/var/log
zfs create ${ZPOOL}/var/spool
zfs create -o com.sun:auto-snapshot=false -o exec=on ${ZPOOL}/var/tmp
chmod 1777 /mnt/var/tmp
debootstrap ${DIST_CODENAME} /mnt
# wait

zfs set devices=off ${ZPOOL}

mkfs.ext4 -F -m 0 -L /boot -j ${PART1}
mkdosfs -F 32 -n EFI ${PART2}
echo "/dev/mapper/${ZPOOL}_crypt / zfs defaults 0 0"  >> /mnt/etc/fstab
UUID1=$(blkid -o value -s UUID ${PART1})
UUID2=$(blkid -o value -s UUID ${PART2})
echo "UUID=${UUID1} /boot auto defaults 0 0" >> /mnt/etc/fstab
echo "UUID=${UUID2} /boot/efi vfat defaults 0 1" >> /mnt/etc/fstab

echo "$TARGET_HOSTNAME" > /mnt/etc/hostname
sed -i 's,localhost,localhost\n127.0.1.1\t'$TARGET_HOSTNAME',' /mnt/etc/hosts
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

chroot /mnt /bin/bash --login

ln -s /proc/self/mounts /etc/mtab
ln -s /dev/mapper/${ZPOOL}_crypt /dev/${ZPOOL}_crypt
echo 'ENV{DM_NAME}=="${ZPOOL}_crypt", SYMLINK+="${ZPOOL}_crypt"' > /etc/udev/rules.d/99-${ZPOOL}_crypt.rules
locale-gen en_US.UTF-8

debconf-set-selections <<EOF
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Copenhagen
tzdata tzdata/Zones/Etc select
EOF
rm /etc/localtime /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${NETWORK_INTERFACE}
iface ${NETWORK_INTERFACE} inet dhcp
EOF

mount /boot
mkdir /boot/efi
mount /boot/efi

cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu ${DIST_CODENAME} main universe multiverse
deb http://security.ubuntu.com/ubuntu ${DIST_CODENAME}-security main universe multiverse
deb http://archive.ubuntu.com/ubuntu ${DIST_CODENAME}-updates main universe multiverse
EOF
apt update
apt install --yes ubuntu-server
apt install --yes --no-install-recommends linux-image-generic
apt install --yes zfs-initramfs cryptsetup grub-efi grub-efi-amd64
apt install --yes ifupdown

addgroup --system lpadmin
addgroup --system sambashare

passwd
# prompt to set root password

UUID3=$(blkid -o value -s UUID ${PART3})
echo "${ZPOOL}_crypt UUID=${UUID3} none luks,discard" >> /etc/crypttab
update-initramfs -c -k all
sed -i 's,GRUB_CMDLINE_LINUX="",GRUB_CMDLINE_LINUX="boot=zfs",' /etc/default/grub
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
apt-get clean
zfs snapshot ${ZPOOL}/ROOT/ubuntu@install

exit

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export ${ZPOOL}

reboot
