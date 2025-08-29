# Borg-go : Scripts for use with BorgBackup

Scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation

 1. Download or clone the `borg-go` repository to a convenient place on your computer, e.g. into `~/Projects/` or `/usr/local/opt/`.

 2. Symlink the `borg-go.sh` file as `borg-go` from a directory on your PATH. You could use `~/.local/bin`, but to simplify running `borg-go` with `sudo`, use a directory on root's path, e.g. `/usr/local/bin`.

 3. The `import_func.sh` script should also be symlinked from the directory on your PATH, so that `borg-go` can import its dependencies. This script is part of the [Bash-Library](https://github.com/AndrewDDavis/Bash-Library) project of functions that support shell scripting. You may wish to install the whole Bash Library, or only the required dependencies of `borg-go`: `docsh`, `err_msg`, `vrb_msg`, `physpath`, `array_match`, `run_vrb`, and `ignore_sigpipe`.

The `bgo_link.sh` script is ~~useful~~ (out of date) for creating the links. Run it with `-h` to see command usage help.

### Installed Scripts

The following commands become available after installation:

- **borg-go**  The main script that is run from the command line as detailed in the usage section, and which calls the other scripts.

- **bgo_chfile_sizes**  Extracts the name of changed files that were backed up in a `borg-go create` run, calculates their sizes, and prints the list of the largest files to the log. This is run automatically after a successful backup.

- **bgo_check_mount**  For systems in which borg is used for backup over a network, but only installed locally and not installed on the receiver. Checks and mounts the backup drive using sshfs if necessary, then unmounts after. Active if the environment contains BORG_MNT_REQD=1.

- **bgo_prep_backupdir**  Runs commands to prepare for the backup, such as generating a list of the installed applications or packages in the ~/.backup directory.

- **bgo_ping_hc**  Sends start and success or failure signals to healthchecks, to facilitate monitoring of backup job success and notify if backups are failing or out of date.

### Configuration

- set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
- also set BORG_MNT_REQD=1 if necessary
- to allow notifications and tracking using healthchecks.io, create the file
  healthchecks_UUID in your BORG_CONFIG_DIR, which should contain the UUID
  of your healthchecks project (see https://healthchecks.io/)

## Usage

A typical run uses a command such as `sudo borg-go create prune check`. The `compact` command is also supported, and the order of the commands is preserved.

Running as the root user (e.g. using `sudo` as above) is generally required when backing up system directories, as some system files can only be read by root. In borg's docs, it is strongly recommended to always access the repository using the same user account to avoid permissions issues in your borg repository or borg cache. For remote repos that are accessed by SSH, it's straightforward to always use the same `ssh user@host` line, regardless of whether you're using sudo. For local repositories, using `user@localhost:/path/to/repo` for BORG_REPO has the same effect, and ensures the same user always accesses the repo.

Depending on the configuration in `/etc/sudoers` and `/etc/sudoers.d/`, which can contain the `secure_path` parameter, the above command may fail because `borg-go` is not in the `sudo` PATH. There are several ways to work around this issue:

- Edit the `sudoers` config to comment the line, add the relevant path, or remove the borg user from the requirement, e.g. by adding the `exempt_group` or using something like `Defaults:!borg_user secure_path="..."`.
- Use `which` or `command` to pass the full path: `sudo $(command -v borg-go) ...`. This can be aliased, e.g. as `bgo`.
- Set the user's PATH: `sudo PATH=$PATH borg-go ...`. This can be aliased, e.g. as `sudop`.

When running the `prune` action, the options provided by `borg-go` should keep every archive within the last 14 days, and weekly archives for 2 weeks that have a backup before that, then similarly for 6 monthly archives, and 3 yearly archives.

## After

Some useful commands to see the result of your borg create/prune runs:

``` bash
cd ~/.config/borg
cat log/borg_stats_create      # stats from the create job
cat log/borg_stats_prune       # stats from the prune job
sort -h log/borg_chfile_sizes  # print size-ordered list of files backed up in most recent job
```
