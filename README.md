# Install Ubuntu on ZFS on LUKS

## Configurable variables
```
export TARGET_HOSTNAME="hostname"
export TIMEZONE=Europe/Copenhagen
export NETWORK_INTERFACE=eth0
export SWAP_SIZE=8G
export DISK=/dev/DEVICE
export BOOT_DEVICE=${DISK}1
export EFI_DEVICE=${DISK}2
export SWAP_DEVICE=${DISK}4
export LUKS_DEVICE=${DISK}3
export DIST_CODENAME=$(lsb_release -sc)
export PACKAGES="ubuntu-server"
export ZPOOL=rpool
```

## Install requirements
```
apt install --yes zfsutils-linux cryptsetup debootstrap dosfstools gdisk
```

## Partition disk
```
sgdisk -o $DISK
sgdisk -n1:1M:+512M -t1:8300 $DISK
sgdisk -n2:0:+256M -t2:EF00 $DISK
sgdisk -n9:-8M:0 -t9:BF07 $DISK
sgdisk -n4:0:+${SWAP_SIZE} -t4:8200 $DISK
sgdisk -n3:0:0 -t3:8300 $DISK
```

## Format and open the LUKS partition
```
cryptsetup luksFormat -c aes-xts-plain64 -s 512 -h sha512 ${LUKS_DEVICE}
cryptsetup luksOpen ${LUKS_DEVICE} ${ZPOOL}_crypt
```

## Create ZFS pool and filesystems
```
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
```

## Bootstrap system in /mnt
```
debootstrap ${DIST_CODENAME} /mnt
```

## Disable device files
```
zfs set devices=off ${ZPOOL}
```

## Format boot- and EFI-partitions
```
mkfs.ext4 -F -m 0 -L /boot -j ${BOOT_DEVICE}
mkdosfs -F 32 -n EFI ${EFI_DEVICE}
echo "/dev/mapper/${ZPOOL}_crypt / zfs defaults 0 0"  >> /mnt/etc/fstab
BOOT_DEVICE_UUID=$(blkid -o value -s UUID ${BOOT_DEVICE})
EFI_DEVICE_UUID=$(blkid -o value -s UUID ${EFI_DEVICE})
echo "UUID=${BOOT_DEVICE_UUID} /boot auto defaults 0 0" >> /mnt/etc/fstab
echo "UUID=${EFI_DEVICE_UUID} /boot/efi vfat defaults 0 1" >> /mnt/etc/fstab
echo "/dev/mapper/swap_crypt none swap sw 0 0" >> /mnt/etc/fstab
```

## Prepare chroot for install
```
echo "$TARGET_HOSTNAME" > /mnt/etc/hostname
sed -i 's,localhost,localhost\n127.0.1.1\t'$TARGET_HOSTNAME',' /mnt/etc/hosts
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
```
```
chroot /mnt /bin/bash --login

ln -s /proc/self/mounts /etc/mtab
ln -s /dev/mapper/${ZPOOL}_crypt /dev/${ZPOOL}_crypt
echo 'ENV{DM_NAME}=="${ZPOOL}_crypt", SYMLINK+="${ZPOOL}_crypt"' > /etc/udev/rules.d/99-${ZPOOL}_crypt.rules
locale-gen en_US.UTF-8
mount /boot
mkdir /boot/efi
mount /boot/efi
```

## Set the timezone
```
IFS=/ read -ra TZ <<< $TIMEZONE
debconf-set-selections <<EOF
tzdata tzdata/Areas select ${TZ[0]}
tzdata tzdata/Zones/${TZ[0]} select ${TZ[1]}
tzdata tzdata/Zones/Etc select
EOF
rm /etc/localtime /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
```

## Setup the networking
```
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${NETWORK_INTERFACE}
iface ${NETWORK_INTERFACE} inet dhcp
EOF
```

## Install packages
```
cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu ${DIST_CODENAME} main universe multiverse
deb http://security.ubuntu.com/ubuntu ${DIST_CODENAME}-security main universe multiverse
deb http://archive.ubuntu.com/ubuntu ${DIST_CODENAME}-updates main universe multiverse
EOF
apt update
apt install --yes $PACKAGES
apt install --yes --no-install-recommends linux-image-generic
apt install --yes zfs-initramfs cryptsetup grub-efi grub-efi-amd64
apt install --yes ifupdown
```

## Create users and groups
```
addgroup --system lpadmin
addgroup --system sambashare

# prompt to set a root password
passwd
```

## Install bootloader
```
LUKS_DEVICE_UUID=$(blkid -o value -s UUID ${LUKS_DEVICE})
echo "${ZPOOL}_crypt UUID=${LUKS_DEVICE_UUID} none luks,discard" >> /etc/crypttab
echo "swap_crypt ${SWAP_DEVICE} /dev/urandom cipher=aes-xts-plain64,size=256,swap,discard" >> /etc/crypttab
update-initramfs -c -k all
sed -i 's,GRUB_CMDLINE_LINUX="",GRUB_CMDLINE_LINUX="boot=zfs",' /etc/default/grub
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
```

## Cleanup and make snapshot
```
apt-get clean
zfs snapshot ${ZPOOL}/ROOT/ubuntu@install
```

## Exit chroot, cleanup and reboot
```
exit

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export ${ZPOOL}

reboot
```
