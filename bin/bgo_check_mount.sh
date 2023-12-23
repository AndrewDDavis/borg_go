#!/usr/bin/env bash

# This script is used for working with borg repos stored on the hippocampus
# NAS (for mendeleev and erikson).
# It checks that the SSHFS volume is mounted, and mounts it if not.
# Run as root for mount/umount (?), with `sudo`
# On macOS, need to install BorgBackup through the tap method with homebrew
# to allow fuse mounting to work.

[[ $(id -u) -eq 0 ]] || { echo "root or sudo required for $(basename -- $0)."; exit 2; }

# Can unmount volume if run with -u
if [[ $# -eq 1 ]] && [[ $1 == '-u' ]]; then
    action=unmount
else
    action=mount
fi

# Define NAS url, repo path, mount-point, and local hostname
nas_url=root@hc
repo_pth='/shares/addavis/Backup'
mnt_pnt='/mnt/hc_backup'
host_nm=$(hostname -s)

if [[ $action == unmount ]]; then
    umount "$mnt_pnt"

elif [[ ! -e ${mnt_pnt}/README ]]; then
    # Ensure backup location is mounted

    # '-o reconnect' should solve the error "mount point ... is itself on a FUSE volume",
    #   caused by disconnect of underlying SSH
    # if not, umount should work
    # could also check for this situation and umount automatically; e.g:
    mount | grep "$mnt_pnt" && { echo "mount broken!?! try: umount -v $mnt_pnt"; }

    if [[ $host_nm == erikson ]]; then
        repodir=borgbackup_erikson_linux_repo

    elif [[ $host_nm == mendeleev ]]; then
        repodir=borgbackup_mendeleev_macos_repo

    else
        echo "Error unkonwn host: $host_nm"
        exit 2
    fi

    # mount ssh volume from hippocampus
    # - to avoid sshfs asking for password, use:
    #   ssh-copy-id root@hc
    #   sudo ssh-copy-id root@hc
    [[ -t 0 && -n $TERM ]] \
        && echo "borg_mount-check: sshfs may ask for remote password for $nas_url..."

    sshfs -o reconnect,allow_other,default_permissions,Ciphers=aes128-ctr \
          "$nas_url":"$repo_pth"/"$repodir"                               \
          "$mnt_pnt"                                                      \
        || sshfs_ec=$?

    if [[ ${sshfs_ec-} -eq 1 ]]; then
        echo "ERROR: sshfs exited with code $ec"
        echo "       possibly requires \`sudo ssh-copy-id $nas_url\`"
        exit 1
    elif [[ ${sshfs_ec-} -gt 1 ]]; then
        echo "sshfs exited with code $ec, unknown error"
        exit $sshfs_ec
    else
        true
    fi
fi
