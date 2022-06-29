#!/bin/bash

# This script is used for working with borg repos stored on the hippocampus
# NAS (for mendeleev and erikson).
# It checks that the SSHFS volume is mounted, and mounts it if not.
# Run as root for mount/umount (?), with `sudo -EH`
# On macOS, need to install BorgBackup through the tap method with homebrew
# to allow fuse mounting to work.

# Can unmount volume if run with -u
if [[ $# -eq 1 ]] && [[ $1 == '-u' ]]; then
    action=unmount
else
    action=mount
fi

# Define mount-point and hostname
mntpnt='/mnt/hc_backup'
hostnm="$(hostname -s)"

if [[ $action == unmount ]]; then
    umount -v "$mntpnt"
fi

# Ensure backup location is mounted
if  [[ ! -e ${mntpnt}/README ]]; then
    # '-o reconnect' should solve the error "mount point ... is itself on a FUSE volume",
    #   caused by disconnect of underlying SSH
    # if not, umount should work
    # could also check for this situation and umount automatically; e.g:
    mount | grep "$mntpnt" && { echo "mount broken!?! try: umount -v $mntpnt"; }

    if [[ $hostnm == erikson ]]; then
        repodir=borgbackup_erikson_linux_repo

    elif [[ $hostnm == mendeleev ]]; then
        repodir=borgbackup_mendeleev_macos_repo

    else
        echo "Error unkonwn host: $hostnm"
        exit 2
    fi

    # mount ssh volume from hippocampus
    sshfs -o reconnect,allow_other,default_permissions,Ciphers=aes128-ctr \
          root@hc:/shares/addavis/Backup/"$repodir" \
          "$mntpnt"
fi
