#!/bin/bash

localization="en"
# localization="de"

# no questions from Debian package manager
export DEBIAN_FRONTEND=noninteractive

# no paging (wait for user scrolling) while Solr installation script
export SYSTEMD_PAGER=""


# update package lists and sources to contrib and non-free
cat <<EOF > ${rootdir}/etc/apt/sources.list
deb http://deb.debian.org/debian/ stable main contrib non-free
deb http://security.debian.org/ stable/updates main contrib non-free
EOF

# wait until network / dns is up
until $(ping -c1 deb.debian.org &>/dev/null); do :; done

apt-get update
apt-get upgrade

# install VM guest additions so later no problems
apt-get -y install linux-image-amd64 linux-headers-amd64 build-essential module-assistant

# mount VM guest additions
mkdir /tmp/cdrom
mount /dev/cdrom /tmp/cdrom
sh /tmp/cdrom/VBoxLinuxAdditions.run
umount /dev/cdrom

# install first, so later no problems
apt-get -y install dbus


# configure debconf options
echo 'Debconf'

debconffilelist=`ls /usr/src/customize/debconf`

for debconffile in ${debconffilelist};
do
    echo "Configurating debconf with ${debconffile}"
    debconf-set-selections /usr/src/customize/debconf/${debconffile}
done

echo 'Debconf (localization)'

debconffilelist=`ls /usr/src/customize/debconf.${localization}`

for debconffile in ${debconffilelist};
do
    echo "Configurating debconf with ${debconffile}"
    debconf-set-selections /usr/src/customize/debconf.${localization}/${debconffile}
done


# packages lists
packagelists=`ls /usr/src/customize/package-lists`

for list in ${packagelists};
do
    echo "Adding packagelist $list"
    packages=`cat /usr/src/customize/package-lists/${list} | xargs`
    packagesparams="$packages $packagesparams"

done

# packages lists for language
packagelists=`ls /usr/src/customize/package-lists.${localization}`

for list in ${packagelists};
do
    echo "Adding packagelist $list"
    packages=`cat /usr/src/customize/package-lists.${localization}/${list} | xargs`
    packagesparams="$packages $packagesparams"

done

echo "Installing packages from packagelists: ${packagesparams}"
apt-get -y install ${packagesparams}

# install custom packages
dpkg --install /usr/src/customize/packages.chroot/*.deb

# install dependencies
apt-get -y -f install

# stop Solr so we can overwrite its config and data
service solr stop

# Add (optional shared) folder for index
mkdir /media/sf_index
mkdir /media/sf_index/tmp

# link Solr index to shared folder
rm -r /var/solr/data/opensemanticsearch/data
ln -s /media/sf_index /var/solr/data/opensemanticsearch/data

# allow Solr to write to index directory, if not external index (so mounted to Virtual Box shared folder and rights from vboxsf group)
chown solr:solr /media/sf_index

# copy overwriting or additional files to root dir
cp -a /usr/src/customize/includes.chroot/* /

# copy files for language to root dir
cp -a /usr/src/customize/includes.chroot.${localization}/* /

# add solr and user to group vboxsf, so they have access to shared folders of host system
usermod -a -G vboxsf solr
usermod -a -G vboxsf opensemanticetl

# delete apt package cache
apt-get clean

# delete installation sources and this script and its temporary startscript /etc/rc.local
rm -r /usr/src/customize

# delete caches (f.e. pip)
rm -r /root/.cache

# delete deleted data on filesystem by filling up ueros, which will increase compression rate on appliance export
dd if=/dev/zero of=/ZEROS bs=1M
sync
rm -f /ZEROS

# add swapfile
fallocate -l 4G ${rootdir}/swapfile
mkswap /swapfile
chmod 600 ${rootdir}/swapfile
cat <<EOF >> ${rootdir}/etc/fstab
/swapfile swap swap defaults 0 0
EOF

# shutdown ready build VM
systemctl poweroff
