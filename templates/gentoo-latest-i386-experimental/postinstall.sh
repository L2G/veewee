#!/bin/bash

# Utility function for sending commands through chroot
function chroot_pipe {
    cat | chroot /mnt/gentoo /bin/bash -
}

date > /etc/vagrant_box_build_time

#Based on http://www.gentoo.org/doc/en/gentoo-x86-quickinstall.xml

#Partition the disk
#This assumes a predefined layout - customize to your own liking

#/boot -> /dev/sda1
#swap -> /dev/sda2
#root -> /dev/sda3

sfdisk --force /dev/sda <<EOF
# partition table of /dev/sda
unit: sectors

/dev/sda1 : start=     2048, size=   409600, Id=83
/dev/sda2 : start=   411648, size=  2097152, Id=82
/dev/sda3 : start=  2508800, size= 18257920, Id=83
/dev/sda4 : start=        0, size=        0, Id= 0
EOF

sleep 2

#Format the /boot
mke2fs /dev/sda1

#Main partition /
mke2fs -j /dev/sda3

#Format the swap and use it
mkswap /dev/sda2
swapon /dev/sda2

#Mount the new disk
mkdir /mnt/gentoo
mount /dev/sda3 /mnt/gentoo
mkdir /mnt/gentoo/boot
mount /dev/sda1 /mnt/gentoo/boot
cd /mnt/gentoo

# Choose list of Gentoo HTTP mirrors. This sets GENTOO_MIRRORS to a list of up
# to 3 URLs for mirrors, all separated by spaces and having a trailing /.
mirrorselect -H -s 3 -D -o >gentoo_mirrors
source gentoo_mirrors && rm gentoo_mirrors
echo "Chosen mirrors: ${GENTOO_MIRRORS}"

#Download stage3 archive
#(the [@] tells bash to break up the words in the variable)
for mirror in ${GENTOO_MIRRORS[@]}; do
    wget -r -l 1 -nd -A ${STAGE3_PATTERN:="stage3-i686-*.tar.bz2"} \
         ${mirror}releases/x86/current-stage3/
    if [ -e ${STATE3_PATTERN} ]; then break; fi
done

if [ ! -e ${STAGE3_PATTERN} ]; then
	echo "Could not download current stage3 tarball; must abort"
	exit 1
fi
tar xjpf ${STAGE3_PATTERN} && rm ${STAGE3_PATTERN}

#Download Portage snapshot
cd /mnt/gentoo/usr
for mirror in ${GENTOO_MIRRORS[@]}; do
    wget ${mirror}releases/snapshots/current/portage-latest.tar.bz2 \
        && break
done

if [ ! -e portage-lat* ]; then
	echo "Could not download Portage tree snapshot; must abort"
	exit 1
fi
tar xjf portage-lat* && rm portage-lat*

#Chroot
cd /
mount -t proc proc /mnt/gentoo/proc
mount --rbind /dev /mnt/gentoo/dev
cp -L /etc/resolv.conf /mnt/gentoo/etc/
chroot_pipe <<< "env-update && source /etc/profile"

# Get the kernel sources
chroot_pipe <<< "emerge gentoo-sources"

# We will use genkernel to automate the kernel compilation
# http://www.gentoo.org/doc/en/genkernel.xml
chroot_pipe <<< "emerge grub"
chroot_pipe <<< "emerge genkernel"
chroot_pipe <<< "genkernel --bootloader=grub --real-root=/dev/sda3 --no-splash --install all"
chroot_pipe <<< "grub-install /dev/sda"

chroot_pipe <<EOF
cat <<FSTAB > /etc/fstab
/dev/sda1   /boot     ext2    noauto,noatime     1 2
/dev/sda3   /         ext3    noatime            0 1
/dev/sda2   none      swap    sw                 0 0
FSTAB
EOF


#We need some things to do here
#Network
chroot_pipe <<EOF
cd /etc/conf.d
echo 'config_eth0=( "dhcp" )' >> net
#echo 'dhcpd_eth0=( "-t 10" )' >> net
#echo 'dhcp_eth0=( "release nodns nontp nois" )' >> net
ln -s net.lo /etc/init.d/net.eth0
rc-update add net.eth0 default
#Module?
rc-update add sshd default
EOF

#Root password

# Cron & Syslog
chroot_pipe <<< "emerge syslog-ng vixie-cron"
chroot_pipe <<< "rc-update add syslog-ng default"
chroot_pipe <<< "rc-update add vixie-cron default"

#Get an editor going
chroot_pipe <<< "emerge vim"

#Allow external ssh
chroot_pipe <<< "echo 'sshd:ALL' > /etc/hosts.allow"
chroot_pipe <<< "echo 'ALL:ALL' > /etc/hosts.deny"

#create vagrant user  / password vagrant
chroot_pipe <<< "useradd -m -r vagrant -p '\$1\$MPmczGP9\$1SeNO4bw5YgiEJuo/ZkWq1'"

#Configure Sudo
chroot_pipe <<< "emerge sudo"
chroot_pipe <<< "echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers"

#Installing vagrant keys
chroot_pipe <<< "emerge wget "

echo "creating vagrant ssh keys"
chroot_pipe <<< "mkdir /home/vagrant/.ssh"
chroot_pipe <<< "chmod 700 /home/vagrant/.ssh"
chroot_pipe <<< "cd /home/vagrant/.ssh"
chroot_pipe <<< "wget --no-check-certificate 'https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub' -O /home/vagrant/.ssh/authorized_keys"
chroot_pipe <<< "chmod 600 /home/vagrant/.ssh/authorized_keys"
chroot_pipe <<< "chown -R vagrant /home/vagrant/.ssh"

#This could be done in postinstall
#reboot

#get some ruby running
chroot_pipe <<< "emerge git curl gcc automake  m4"
chroot_pipe <<< "emerge libiconv readline zlib openssl curl git libyaml sqlite libxslt"
chroot_pipe <<< "curl -s https://rvm.beginrescueend.com/install/rvm"
chroot_pipe <<< "/usr/local/rvm/bin/rvm install ruby-1.8.7 "
chroot_pipe <<< "/usr/local/rvm/bin/rvm use ruby-1.8.7 --default "

#Installing chef & Puppet
chroot_pipe <<< ". /usr/local/rvm/scripts/rvm ; gem install chef --no-ri --no-rdoc"
chroot_pipe <<< ". /usr/local/rvm/scripts/rvm ; gem install puppet --no-ri --no-rdoc"


echo "adding rvm to global bash rc"
chroot_pipe <<< "echo '. /usr/local/rvm/scripts/rvm' >> /etc/bash/bash.rc"

/bin/cp -f /root/.vbox_version /mnt/gentoo/home/vagrant/.vbox_version
VBOX_VERSION=$(cat /root/.vbox_version)

#Kernel headers
chroot_pipe <<< "emerge linux-headers"

#Installing the virtualbox guest additions
mkdir /mnt/gentoo/mnt/vbox
mount -o loop VBoxGuestAdditions_$VBOX_VERSION.iso /mnt/gentoo/mnt/vbox
chroot_pipe <<< "sh /mnt/vbox/VBoxLinuxAdditions.run"
umount /mnt/gentoo/mnt/vbox
rmdir /mnt/gentoo/mnt/vbox
rm VBoxGuestAdditions_$VBOX_VERSION.iso

rm -rf /mnt/gentoo/usr/portage/distfiles
mkdir /mnt/gentoo/usr/portage/distfiles
chroot_pipe <<< "chown portage:portage /usr/portage/distfiles"

chroot_pipe <<< "sed -i 's:^DAEMONS\(.*\))$:DAEMONS\1 rc.vboxadd):' /etc/rc.conf"

exit
cd /
umount /mnt/gentoo/{proc,sys,dev}
umount /mnt/gentoo

reboot
