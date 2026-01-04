#!/usr/bin/env bash

# Make a list of installed software and packages, which can be used for later
# reinstallation in the case of disk failure.
#
# Part of the borg-go project, see: https://github.com/AndrewDDavis/borg_go

# Configure some common variables, shell options, and functions
src_dir=$( command python3 -c "import os; print(os.path.dirname(os.path.realpath('${BASH_SOURCE[0]}')))" )
builtin source "$src_dir/bgo_env_setup.sh"

# store these file and application lists in logged-in user's home
# - lognm variables set in bgo_env_setup
bakdir="$lognm_home/.local/backups"
[[ -d "$bakdir" ]] \
    || /bin/mkdir -p "$bakdir"


# Create a list of what's in /usr/local (nullglob is set)
printf '%s\n\n' '/usr/local/'       >  "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/              >> "$bakdir"/usr-local-list.txt
printf '\n\n%s\n\n' '/usr/local/*'  >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*             >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/share/man     >> "$bakdir"/usr-local-list.txt

# - also show it in tree form
command tree -a /usr/local > "$bakdir"/usr-local-tree.txt


# The (p/m)locate db also contains paths for most files on the system
if [[ -n ${LOCATE_PATH:-} ]]
then
    dbfile=$LOCATE_PATH

elif [[ -r /var/lib/plocate/plocate.db ]]
then
    dbfile=/var/lib/plocate/plocate.db
fi

if [[ -r ${dbfile:-} ]]
then
    if [[ ! -e "$bakdir"/"$(basename "$dbfile")" ]] \
        || ! cmp -s "$dbfile" "$bakdir"/"$(basename "$dbfile")"
    then
        /bin/cp -p "$dbfile" "$bakdir"
    fi
fi


# List packages installed through npm, pip, pipx, and flatpak
# - you may need to pass PIPX_GLOBAL_HOME if set

if npm_cmd=$( builtin type -P npm )
then
    "$npm_cmd" --version > "${bakdir}/npm-list-g.txt"
    "$npm_cmd" list -g --depth=0 >> "${bakdir}/npm-list-g.txt"
fi

if pip_cmd=$( builtin type -P pip )
then
    "$pip_cmd" --version > "${bakdir}/pip-list.txt"
    "$pip_cmd" list >> "${bakdir}/pip-list.txt"
fi

if pipx_cmd=$( builtin type -P pipx )
then
    if [[ ! -v PIPX_GLOBAL_HOME && -d /usr/local/opt/pipx ]]
    then
        export PIPX_GLOBAL_HOME=/usr/local/opt/pipx
    fi

    "$pipx_cmd" --version > "${bakdir}/pipx-list-global.txt"
    "$pipx_cmd" list --global >> "${bakdir}/pipx-list-global.txt"
fi

if fp_cmd=$( builtin type -P flatpak )
then
    "$fp_cmd" --version > "${bakdir}/flatpak-list-app.txt"
    "$fp_cmd" list --app >> "${bakdir}/flatpak-list-app.txt"
fi

# Back up "Session Buddy" backup files of the Chrome state, if any
# - probably in ~/Downloads
"$find_cmd" "$lognm_home"/Downloads/ -maxdepth 2 \
    -name 'session_buddy_backup*.json' \
    -exec /bin/mv -f {} "$bakdir" \;


# Backup VS-Code user settings files
if [[ -r "$lognm_home"/.config/Code/User/settings.json ]]
then
    vsc_bakdir="$bakdir"/vscode-user_config
    /bin/mkdir -p "$vsc_bakdir"
    for fn in "$lognm_home"/.config/Code/User/{settings.json,keybindings.json,snippets}
    do
        [[ -r $fn ]] && /bin/cp -pfLR "$fn" "$vsc_bakdir"/
    done
    unset fn vsc_bakdir
fi


# OS dependent files
# - mach_name and mach_os defined in bgo_env_setup
if [[ $mach_os == linux ]]
then
    if [[ -n $( command -v dpkg ) ]]
    then
        # Debian-based system
        # create a list of installed packages from dpkg
        # - Source for dpkg cmd:
        #   http://www.webupd8.org/2010/03/2-ways-of-reinstalling-all-of-your.html
        # - Note, /var/backups contains backups of the dpkg-status file, but that doesn't
        #   appear to indicate manual vs automatic installations.
        command dpkg --get-selections > "$bakdir"/dpkg-installed-applications.txt

        # To restore the dpkg list, use:
        #  sudo dpkg --set-selections < dpkg-installed-applications.txt
        #  sudo apt-get -y update
        #  sudo apt-get dselect-upgrade

        # specifically note manually installed packages
        command apt-mark showmanual > "$bakdir"/apt-manual-packages.txt

        # also backup the sources list(s)
        [[ -r /etc/apt/sources.list ]] \
            && /bin/cp -pfLR /etc/apt/sources.list "$bakdir"/apt-sources.list
        [[ -d /etc/apt/sources.list.d ]] \
            && /bin/cp -pfLR /etc/apt/sources.list.d "$bakdir"/apt-sources.list.d
    fi

    if dconf_cmd=$( builtin type -P dconf )
    then
        # back up user gsettings database if available
        # - if a restore is needed, you can use:
        #   cp ~/.config/dconf/user /tmp
        #   XDG_CONFIG_HOME=/tmp dconf dump / > old-gsettings-data.txt
        if (( $( command id -u ) == 0 ))
        then
            sudo -u "$lognm" "$dconf_cmd" dump / > "$bakdir"/dconf-dump_backup.dump
        else
            "$dconf_cmd" dump / > "$bakdir"/dconf-dump_backup.dump
        fi
    fi

elif [[ $mach_os == macos ]]
then
    # create a list of installed applications (nullglob is set)
    /bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt
else
    err_msg -d 2 "Undefined mach_os: $mach_os"
    exit
fi

# chown these files to user
# - could also use ACLs with setfacl here, to preserve orig ownership
"$chown_cmd" -R "$lognm":"$lognm_group" "$bakdir"
