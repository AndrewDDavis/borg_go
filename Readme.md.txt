# Scripts for use with BorgBackup

scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation

I symlink these from `~/.local/bin`, omitting the `.sh` suffix. Make sure it is in your PATH. choose the appropriate pre-backup script to symlink based on your OS.
The **borg_go_links.sh** script is useful for creating the links.


### Installed Scripts

The following commands become available after installation:
- **borg_go**  The main script that is run from the command line as detailed in the usage section, and which calls the other scripts.
- **borg_chfile_sizes**  Extracts the name of changed files that were backed up in a `borg_go create` run, calculates their sizes, and prints the list of the largest files to the log.
- **borg_mount-check**  For systems in which borg is used for backup over a network, but only installed locally and not installed on the receiver. Checks and mounts the backup drive using sshfs if necessary, then unmounts after. Active if the environment contains BORG_MNT_REQD=1.
- **borg_pre-backup**  Runs commands to prepare for the backup, such as generating a list of the installed applications or packages in the ~/.backup directory.
- **hc_ping**  Sends start and success or failure signals to healthchecks, to facilitate monitoring of backup job success and notify if backups are failing or out of date.

## Usage

1. edit `borg_go` to your heart's content
2. run using `sudo -EH borg_go create prune check`. compact is also supported, order of the commands is preserved.

## After

Some useful commands to see the result of your borg create/prune runs:

``` bash
cd ~/.config/borg
cat borg_stats_create.txt      # stats from the create job
cat borg_stats_prune.txt       # stats from the prune job
sort -h borg_chfile_sizes.txt  # print size-ordered list of files backed up in most recent job
```
