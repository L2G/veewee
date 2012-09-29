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

#Note: we retry as sometimes mirrors fail to have the files

#Download a stage3 archive
while true; do
	wget ftp://distfiles.gentoo.org/gentoo/releases/x86/current-stage3/stage3-i686-*.tar.bz2 && > gotstage3
        if [ -f "gotstage3" ]
        then
		break
	else
		echo "trying in 2seconds"
		sleep 2
        fi
done
tar xjpf stage3*

#Download Portage snapshot
cd /mnt/gentoo/usr
while true; do
        wget http://distfiles.gentoo.org/releases/snapshots/current/portage-latest.tar.bz2 && > gotportage
        if [ -f "gotportage" ]
        then
		break
	else
		echo "trying in 2seconds"
		sleep 2
	fi
done

tar xjf portage-lat*

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
chroot_pipe <<< "genkernel --bootloader=grub --real_root=/dev/sda3 --no-splash --install all"

chroot_pipe <<EOF
/sbin/grub --batch --device-map=/dev/null <<GRUBEOF
device (hd0) /dev/sda
root (hd0,0)
setup (hd0)
quit
GRUBEOF
EOF

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
chroot_pipe <<< "useradd -m -r vagrant -p '$1$MPmczGP9$1SeNO4bw5YgiEJuo/ZkWq1'"

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
chroot_pipe <<EOF
mkdir /mnt/vbox
mount -o loop VBoxGuestAdditions_$VBOX_VERSION.iso /mnt/vbox
sh /mnt/vbox/VBoxLinuxAdditions.run
umount /mnt/vbox
rm VBoxGuestAdditions_$VBOX_VERSION.iso
EOF

rm -rf /mnt/gentoo/usr/portage/distfiles
mkdir /mnt/gentoo/usr/portage/distfiles
chroot_pipe <<< "chown portage:portage /usr/portage/distfiles"

chroot_pipe <<< "sed -i 's:^DAEMONS\(.*\))$:DAEMONS\1 rc.vboxadd):' /etc/rc.conf"

exit
cd /
umount /mnt/gentoo/{proc,sys,dev}
umount /mnt/gentoo

reboot
