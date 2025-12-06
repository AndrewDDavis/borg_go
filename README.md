# Borg-go : Scripts for use with BorgBackup

Scripts to automate and support running backups using [BorgBackup](https://www.borgbackup.org/).

## Installation and Config

 1. Download or clone the `borg-go` repository to a convenient place on your computer, e.g. into `~/Projects/` or `/usr/local/opt/`.

 2. Symlink the `borg-go.sh` file as `borg-go` from a directory on your PATH. You could use `~/.local/bin`, but to simplify running `borg-go` with `sudo`, use a directory on root's path, e.g. `/usr/local/bin`.

 3. The `import_func.sh` script should also be symlinked from the directory on your PATH, so that `borg-go` can import its dependencies. This script is part of the [Bash-Library](https://github.com/AndrewDDavis/Bash-Library) project of functions that support shell scripting. You may wish to install the whole Bash Library, or only the required dependencies to run `borg-go`:
 `docsh`, `err_msg`, `vrb_msg`, `physpath`, `array_match`, `run_vrb`, `ignore_sigpipe`, and `rotate_logs`.

 4. Create `~/.config/borg/` (or your BORG_CONFIG_DIR), and copy, symlink, or define the `patterns*` and `rec_roots*` configuration files within. The files should not have extensions, e.g. `patterns_0` will be read, but `patterns.bak` will be ignored. The patterns files should be named to enforce an alphanumeric reading order. Since the first matching pattern wins in the case of conflicts, machine-specific patterns should come first to allow overrides.

    It is recommended to define BORG_LOGGING_CONF to point to a file called `logging.conf` in the config directory, as well as specific files `logging-dryrun.conf` and `logging-local.conf`.

    The `bgo_link.sh` script was ~~useful~~ for creating the links, but is now out of date. Run it with `-h` to see command usage help.

    Set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF. This may be done in ... Also set `BORG_MNT_REQD=1` if necessary. Set BORG_LOCAL_REPO if you plan to run using the `--local` option.

    To allow notifications and tracking using healthchecks.io, create the file healthchecks_UUID in your BORG_CONFIG_DIR, which should contain the UUID of your healthchecks project (see https://healthchecks.io/).

## Usage

The typical commands to `borg-go` mirror the common commands of `borg`: `create`, `prune`, `check`, `compact`, and `list`. The commands mainly run their Borg counterparts in the order requested, using a predefined set of patterns and options. However, the `create` command rotates the log files before creating a new backup archive, and the `compact` command is run automatically after a succsessful `prune`. The recommended `borg-go` call is `sudo borg-go create prune check`. The `list` and `log` commands may be run with or without `sudo`.

Running as the root user (e.g. using `sudo` as above) is generally required when backing up system directories, as some system files can only be read by root. Thus, `borg-go` enforces running as root when using the `create` command, unless using `--local`, for the reasons noted in the next paragraph. Restore operations also often need root, as [noted here](https://borgbackup.readthedocs.io/en/stable/deployment/non-root-user.html). However, `borg-go` does not support restore operations -- the `extract`, `mount`, and `export-tar` commands would be run directly using `borg`.

Borg's docs strongly recommend to always access the repository using the same user account to avoid permissions issues in your borg repository or borg cache. For remote repos that are accessed by SSH, it's straightforward to always use the same `ssh user@host` line, regardless of whether you're running as a regular user or as root. Since the same remote user always accesses the repo, no permissions problems result. For local repositories, using `user@localhost:/path/to/repo` for BORG_REPO has the same effect, and ensures the same user always accesses the repo.

Depending on the configuration in `/etc/sudoers` and `/etc/sudoers.d/`, which can contain the `secure_path` parameter, the above command may fail because `borg-go` is not in the `sudo` PATH. There are several ways to work around this issue:

- Edit the `sudoers` config to comment the line, add the relevant path, or remove the borg user from the requirement, e.g. by adding the `exempt_group` or using something like `Defaults:!borg_user secure_path="..."`.
- Use `which` or `command` to pass the full path: `sudo $(command -v borg-go) ...`. This can be aliased, e.g. as `bgo`.
- Set the user's PATH: `sudo PATH=$PATH borg-go ...`. This can be aliased, e.g. as `sudop`.

When running the `prune` action, the options provided by `borg-go` should keep every archive within the last 14 days, and weekly archives for 2 weeks that have a backup before that, then similarly for 6 monthly archives, and 3 yearly archives.

### Installed Scripts

The following commands become available after installation:

- **borg-go**  The main script that is run from the command line as detailed in the usage section, and which calls the other scripts.

- **bgo_chfile_sizes**  Extracts the name of changed files that were backed up in a `borg-go create` run, calculates their sizes, and prints the list of the largest files to the log. This is run automatically after a successful backup.

- **bgo_check_mount**  For systems in which borg is used for backup over a network, but only installed locally and not installed on the receiver. Checks and mounts the backup drive using sshfs if necessary, then unmounts after. Active if the environment contains BORG_MNT_REQD=1.

- **bgo_prep_backupdir**  Runs commands to prepare for the backup, such as generating a list of the installed applications or packages in the ~/.backup directory.

- **bgo_ping_hc**  Sends start and success or failure signals to healthchecks, to facilitate monitoring of backup job success and notify if backups are failing or out of date.

## After

Some useful commands to see the result of your borg create/prune runs:

``` bash
cd ~/.config/borg
cat log/borg_stats_create      # stats from the create job
cat log/borg_stats_prune       # stats from the prune job
sort -h log/borg_chfile_sizes  # print size-ordered list of files backed up in most recent job
```
