# Scripts for use with BorgBackup

scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation

I symlink these from `~/.local/bin`, omitting the `.sh` suffix. Make sure it is in your PATH. choose the appropriate pre-backup script to symlink based on your OS.

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
