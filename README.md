# Install Ubuntu on ZFS on LUKS

## Configurable variables
```
export TARGET_HOSTNAME="hostname"
export NETWORK_INTERFACE=eth0
export DISK=/dev/sdX
export PART1=${DISK}1
export PART2=${DISK}2
export PART3=${DISK}3
export DIST_CODENAME=$(lsb_release -sc)
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
sgdisk -n3:0:0 -t3:8300 $DISK
```

## Format and open the LUKS partition
```
cryptsetup luksFormat -c aes-xts-plain64 -s 512 -h sha512 ${PART3}
cryptsetup luksOpen ${PART3} rpool_crypt
```

## Create ZFS pool and filesystems
```
zpool create -o ashift=12 -O atime=off -O canmount=off -O compression=lz4 -O normalization=formD -O mountpoint=/ -R /mnt rpool /dev/mapper/rpool_crypt
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zfs create -o setuid=off rpool/home
zfs create -o mountpoint=/root rpool/home/root
zfs create -o canmount=off -o setuid=off -o exec=off rpool/var
zfs create -o com.sun:auto-snapshot=false rpool/var/cache
zfs create rpool/var/log
zfs create rpool/var/spool
zfs create -o com.sun:auto-snapshot=false -o exec=on rpool/var/tmp
chmod 1777 /mnt/var/tmp
```

## Bootstrap system in /mnt
```
debootstrap ${DIST_CODENAME} /mnt
```

## Disable device files
```
zfs set devices=off rpool
```

## Format boot- and EFI-partitions
```
mkfs.ext4 -F -m 0 -L /boot -j ${PART1}
mkdosfs -F 32 -n EFI ${PART2}
echo "/dev/mapper/rpool_crypt / zfs defaults 0 0"  >> /mnt/etc/fstab
UUID1=$(blkid -o value -s UUID ${PART1})
UUID2=$(blkid -o value -s UUID ${PART2})
echo "UUID=${UUID1} /boot auto defaults 0 0" >> /mnt/etc/fstab
echo "UUID=${UUID2} /boot/efi vfat defaults 0 1" >> /mnt/etc/fstab
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
ln -s /dev/mapper/rpool_crypt /dev/rpool_crypt
echo 'ENV{DM_NAME}=="rpool_crypt", SYMLINK+="rpool_crypt"' > /etc/udev/rules.d/99-rpool_crypt.rules
locale-gen en_US.UTF-8
mount /boot
mkdir /boot/efi
mount /boot/efi
```

## Set the timezone
```
debconf-set-selections <<EOF
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Copenhagen
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
apt install --yes ubuntu-server
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
UUID3=$(blkid -o value -s UUID ${PART3})
echo "rpool_crypt UUID=${UUID3} none luks,discard" >> /etc/crypttab
update-initramfs -c -k all
sed -i 's,GRUB_CMDLINE_LINUX="",GRUB_CMDLINE_LINUX="boot=zfs",' /etc/default/grub
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
```

## Cleanup and make snapshot
```
apt-get clean
zfs snapshot rpool/ROOT/ubuntu@install
```

## Exit chroot, cleanup and reboot
```
exit

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export rpool

reboot
```
