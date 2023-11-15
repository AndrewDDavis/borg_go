# Borg-go : Scripts for use with BorgBackup

Scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation

I symlink these scripts from `~/.local/bin`, omitting the `.sh` suffix.
- Make sure the directory is in your PATH.
- Choose the appropriate pre-backup script to symlink based on your OS.

The **borg_go_links.sh** script is useful for creating the links.

### Installed Scripts

The following commands become available after installation:
- **borg_go**  The main script that is run from the command line as detailed in the usage section, and which calls the other scripts.
- **borg_chfile_sizes**  Extracts the name of changed files that were backed up in a `borg_go create` run, calculates their sizes, and prints the list of the largest files to the log.
- **borg_mount-check**  For systems in which borg is used for backup over a network, but only installed locally and not installed on the receiver. Checks and mounts the backup drive using sshfs if necessary, then unmounts after. Active if the environment contains BORG_MNT_REQD=1.
- **borg_pre-backup**  Runs commands to prepare for the backup, such as generating a list of the installed applications or packages in the ~/.backup directory.
- **hc_ping**  Sends start and success or failure signals to healthchecks, to facilitate monitoring of backup job success and notify if backups are failing or out of date.

### Configuration

- set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
- also set BORG_MNT_REQD=1 if necessary
- to allow notifications and tracking using healthchecks.io, create the file
  healthchecks_UUID.txt in your BORG_CONFIG_DIR, which should contain the UUID
  of your healthchecks project (see https://healthchecks.io/) 

## Usage

A typical run uses the command `sudo -EH borg_go create prune check`. The `compact` command is also supported, and the order of the commands is preserved.

Depending on the `/etc/sudoers` configuration, which can contain the `secure_path` parameter, the above command may fail because `borg_go` is not in the `sudo` PATH. There are several ways to work around this issue:

- Edit the `/etc/sudoers` config to comment the line, add the relevant path, or remove the borg user from the requirement, e.g. by adding the `exempt_group` or using something like `Defaults:!borg_user secure_path="..."`.
- Use which or command: `sudo -EH $(command -v borg_go) ...`. This can be aliased, e.g. as `bgo`.
- Use env: `sudo -EH env PATH=$PATH borg_go ...`. This can be aliased, e.g. as `sudop`.

## After

Some useful commands to see the result of your borg create/prune runs:

``` bash
cd ~/.config/borg
cat borg_stats_create.txt      # stats from the create job
cat borg_stats_prune.txt       # stats from the prune job
sort -h borg_chfile_sizes.txt  # print size-ordered list of files backed up in most recent job
```
