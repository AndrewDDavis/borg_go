# Borg-go : Scripts for use with BorgBackup

Scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation

I symlink these scripts from `~/.local/bin`, omitting the `.sh` suffix.
- Make sure the directory you symlink to is in your PATH.
- Choose the appropriate pre-backup script to symlink based on your OS.

The `bgo_link.sh` script is useful for creating the links. Run it with `-h` to see command usage help.

### Installed Scripts

The following commands become available after installation:

- **borg-go**  The main script that is run from the command line as detailed in the usage section, and which calls the other scripts.

- **bgo_chfile_sizes**  Extracts the name of changed files that were backed up in a `borg-go create` run, calculates their sizes, and prints the list of the largest files to the log.

- **bgo_check_mount**  For systems in which borg is used for backup over a network, but only installed locally and not installed on the receiver. Checks and mounts the backup drive using sshfs if necessary, then unmounts after. Active if the environment contains BORG_MNT_REQD=1.

- **bgo_prep_backup**  Runs commands to prepare for the backup, such as generating a list of the installed applications or packages in the ~/.backup directory.

- **bgo_ping_hc**  Sends start and success or failure signals to healthchecks, to facilitate monitoring of backup job success and notify if backups are failing or out of date.

### Configuration

- set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
- also set BORG_MNT_REQD=1 if necessary
- to allow notifications and tracking using healthchecks.io, create the file
  healthchecks_UUID.txt in your BORG_CONFIG_DIR, which should contain the UUID
  of your healthchecks project (see https://healthchecks.io/)

## Usage

A typical run uses a command such as `sudo borg-go create prune check`. The `compact` command is also supported, and the order of the commands is preserved.

Running as the root user (e.g. using `sudo` as above) is generally required when backing up system directories, as some system files can only be read by root. In borg's docs, it is strongly recommended to always access the repository using the same user account to avoid permissions issues in your borg repository or borg cache. For remote repos that are accessed by SSH, it's straightforward to always use the same `ssh user@host` line, regardless of whether you're using sudo. For local repositories, using `user@localhost:/path/to/repo` for BORG_REPO has the same effect, and ensures the same user always accesses the repo.

Depending on the configuration in `/etc/sudoers` and `/etc/sudoers.d/`, which can contain the `secure_path` parameter, the above command may fail because `borg-go` is not in the `sudo` PATH. There are several ways to work around this issue:

- Edit the `sudoers` config to comment the line, add the relevant path, or remove the borg user from the requirement, e.g. by adding the `exempt_group` or using something like `Defaults:!borg_user secure_path="..."`.
- Use `which` or `command` to pass the full path: `sudo $(command -v borg-go) ...`. This can be aliased, e.g. as `bgo`.
- Set the user's PATH: `sudo PATH=$PATH borg-go ...`. This can be aliased, e.g. as `sudop`.

## After

Some useful commands to see the result of your borg create/prune runs:

``` bash
cd ~/.config/borg
cat log/borg_stats_create.txt      # stats from the create job
cat log/borg_stats_prune.txt       # stats from the prune job
sort -h log/borg_chfile_sizes.txt  # print size-ordered list of files backed up in most recent job
```
