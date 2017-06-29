#!/bin/sh

#localization="de"
localization="en"


# Kill all processes that were run from within the chroot environment
# $1: mount base location
do_kill_all()
{
    if [ -z "$1" ]; then
        echo "No path for finding stray processes: not reaping processes in chroot"
    fi

    echo "Killing processes run inside $1"
    ls /proc | egrep '^[[:digit:]]+$' |
    while read pid; do
        # Check if process root are the same device/inode as chroot
        # root (for efficiency)
        if [ /proc/"$pid"/root -ef "$1" ]; then
            # Check if process and chroot root are the same (may be
            # different even if device/inode match).
            root=$(readlink /proc/"$pid"/root || true)
            if [ "$root" = "$1" ]; then
                exe=$(readlink /proc/"$pid"/exe || true)
                echo "Killing left-over pid $pid (${exe##$1})"
                echo "  Sending SIGTERM to pid $pid"

                kill $pid

                count=0
                max=5
                while [ -d /proc/"$pid" ]; do
                    count=$(( $count + 1 ))
                    echo "  Waiting for pid $pid to shut down... ($count/$max)"
                    sleep 1
                # Wait for $max seconds for process to die before -9'ing it
                    if [ "$count" -eq "$max" ]; then
                        echo "  Sending SIGKILL to pid $pid"
                        kill -9 "$pid"
                        sleep 1
                        break
                    fi
                done
            fi
        fi
    done
}


rootdir=$1


export DEBIAN_FRONTEND=noninteractive

mount -o bind /dev ${rootdir}/dev
mount -o bind /proc ${rootdir}/proc
# Mounting /sys
mount sysfs-live -t sysfs ${rootdir}/sys

#mount -t tmpfs tmpfs ${rootdir}/tmp

mkdir /tmp/build-vm
mount -o bind /tmp/build-vm ${rootdir}/tmp


# update package lists and sources to contrib and non-free
cat <<EOF > ${rootdir}/etc/apt/sources.list
deb http://ftp2.de.debian.org/debian/ stable main contrib non-free
deb http://security.debian.org/ stable/updates main contrib non-free
deb http://ftp.debian.org/debian jessie-backports main
EOF

chroot ${rootdir} apt-get update


# configure debconf options
echo 'Debconf'

mkdir ${rootdir}/tmp/debconf

cp -a debconf/* ${rootdir}/tmp/debconf
cp -a debconf.${localization}/* ${rootdir}/tmp/debconf

debconffilelist=`ls ${rootdir}/tmp/debconf`

for debconffile in ${debconffilelist};
do
    echo "Configurating debconf with ${debconffile}"
    chroot ${rootdir} debconf-set-selections /tmp/debconf/${debconffile}
    chroot ${rootdir} cat /tmp/debconf/${debconffile}

done



# packages lists
packagelists=`ls package-lists`

for list in ${packagelists};
do
    echo "Adding packagelist $list"
    packages=`cat package-lists/${list} | xargs`
    packagesparams="$packages $packagesparams"

done

# packages lists for language
packagelists=`ls package-lists.${localization}`

for list in ${packagelists};
do
    echo "Adding packagelist $list"
    packages=`cat package-lists.${localization}/${list} | xargs`
    packagesparams="$packages $packagesparams"

done

echo "Installing packages from packagelists: ${packagesparams}"
chroot ${rootdir} apt-get -y install ${packagesparams}

#
# REPAIR
#

# new PHP package doesn't run with new Apache module "mpm_event", switch to old Apache module "prefork"
chroot ${rootdir} a2dismod mpm_event
chroot ${rootdir} a2enmod mpm_prefork

# Newer Java (dependency of Solr) from backports

# install java from backports
chroot ${rootdir} apt-get -y install -t jessie-backports openjdk-8-jre-headless

# Set Java to backports version
chroot ${rootdir} update-java-alternatives -s java-1.8.0-openjdk-amd64

# install custom packages
mkdir ${rootdir}/tmp/packages
cp packages.chroot/* ${rootdir}/tmp/packages

# use command as parameter, so the wildcard * wont be extracted/expanded in this running bash script here but inside the chroot
chroot ${rootdir} bash -c "dpkg --install /tmp/packages/*.deb"

# install dependencies
chroot ${rootdir} apt-get -y -f install

# rm packages temps
rm ${rootdir}/tmp/packages/*
rmdir ${rootdir}/tmp/packages





# set locales (locales options have been set in language debconfs)
#chroot ${rootdir} dpkg-reconfigure locales
#chroot ${rootdir} dpkg-reconfigure keyboard-configuration


# copy files to root dir
cp -a includes.chroot/* ${rootdir}

# copy files for language to root dir
cp -a includes.chroot.${localization}/* ${rootdir}

# run hooks inside chroot to configure the new system
mkdir ${rootdir}/tmp/hooks
cp -a hooks/*.chroot ${rootdir}/tmp/hooks

# run the hook
chroot ${rootdir} /tmp/hooks/config.chroot

# add solr and user to group vboxsf, so they have access to shared folders of host system
chroot ${rootdir} usermod -a -G vboxsf solr
chroot ${rootdir} usermod -a -G vboxsf opensemanticetl


# rm hook temps
rm ${rootdir}/tmp/hooks/*
rmdir ${rootdir}/tmp/hooks


# delete apt package cache
chroot ${rootdir} apt-get clean


# stop all services

chroot ${rootdir} service solr stop
chroot ${rootdir} service apache2 stop
chroot ${rootdir} service swapspace stop
chroot ${rootdir} service avahi-daemon stop
chroot ${rootdir} service bluetooth stop
chroot ${rootdir} service network-manager stop


#chroot ${rootdir} service gdm3 stop
#chroot ${rootdir} service networking stop
#chroot ${rootdir} service procps stop
#chroot ${rootdir} service dbus stop



# umount all directories and sockets

# to be able to unmount it, kill all processes running in the chroot
do_kill_all $rootdir

# Workaround binfmt-support /proc locking
if [ -e ${rootdir}/proc/sys/fs/binfmt_misc/status ]
then
	umount ${rootdir}/proc/sys/fs/binfmt_misc
fi

umount -f ${rootdir}/tmp

umount -f ${rootdir}/dev

umount -f ${rootdir}/proc

umount -f ${rootdir}/sys/fs/cgroup/systemd
umount -f ${rootdir}/sys/fs/cgroup
umount -f ${rootdir}/sys

