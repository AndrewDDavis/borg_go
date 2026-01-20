#!/usr/bin/env bash

: """Run Borg-Backup with a static configuration

    Usage

        borg-go [options] <command> [cmd-args] [command ...]

    Borg-go calls the borg command to create, check, and modify backups using the
    typical settings for the present system. For instructions on setting up the
    configuration, refer to the README file.

    Examples

        borg-go create prune check
        borg-go --local create ~/./Documents
        borg-go --local list
        borg-go --local check --repair

    Commands

      create [path ...]
      : Create a new backup archive in the default repository.

        If paths are given after the create command (and before another command),
        they will be used as the recursion roots for the backup, instead of those
        configured in 'rec_roots' config files. Consider using the borg slashdot
        notation for more concise and portable paths within the repo, as in
        the example above.

        Pattern config files are still used to exclude unwanted files such as
        cache directories. This only works as intended when the recursion roots
        are in separate files from the other patterns.

      prune
      : Remove old archives according to the configured rules.

      check
      : Check integrity of the repo and the latest archive.

        The default options for check are --last 1 -a '{hostname}-*'. Use option
        --all to check all archives instead. Additional selections may be made
        along with --all using the command arguments.

      compact
      : Reclaim space in the repo. This runs automatically after prune.

      list [args]
      : List recent backup archives, or contents of a specified archive. Arguments
        may be supplied to provide options to the list command, or specify a
        repository or a particular archive to list. By default, the options
        --consider-checkpoints and --last=10 are used, and the default repository
        is listed unless the --local option was used. No other commands may be
        used with list.

      log
      : Show the most recent log file using less. Respects --dry-run and --local.
        No other commands may be used with log.

    Options

      --local
      : Backup to an alternative repo, e.g. a repo on a local disk. This is
        indended to be used when the regular repo is not available, or for quick,
        one-off backups.

        To use this option, set the BORG_LOCAL_REPO environment variable to the
        path of the alternative repo. In this mode, a separate log file is used,
        and borg-go does not enforce running as root.

        It is common to supply paths to the create command when running in local
        mode, as in the example below. If no paths are given, the configured
        recursion roots are used to create a full backup to the local repo.

      -n, --dry-run
      : Run create and/or prune without changing the repo, to see what would be
        backed up or removed. The check and compact commands are not affected by
        the dry-run option, but compact will not run automatically after prune on
        a dry-run. This option also increases verbosity as in -v.

      -v, --verbose
      : Increase verbosity level of borg-go. Borg itself runs with --info verbosity.
"""

borg-go() {

    # setup the environment:
    # - shell options, umask, variables for mach_os, lognm, etc., via the
    #   bgo_env_setup.sh script
    # - ERR trap would cause exit for non-zero return statuses in this function,
    #   if errtrace was set...
    # - also import required functions such as _bg_args, bg_create, etc.
    _bg_setup

    # handle args
    # - keep track of create/prune/check to preserve order
    local cmd_array=() bgl_args=() cre_args=() pru_args=() chk_args=() com_args=() \
        _dryrun _local _chk_all rr_paths=()
    _bg_args "$@"
    shift $#

    # lock file, mount repo, log file, ensure BORG_CONFIG_DIR, BORG_REPO, etc.
    local repo_uri log_fn logging_dir
    _bg_pre-run

    # check for list or log command
    bg_list && exit
    bg_log && exit

    # Main ops
    local cmd cre_rc chk_rc
    for cmd in "${cmd_array[@]}"
    do
        case "$cmd" in
            ( create )
                bg_create
            ;;
            ( prune )
                bg_prune
                [[ ! -v _dryrun ]] \
                    && bg_compact
            ;;
            ( check )
                bg_check
            ;;
            ( compact )
                bg_compact
            ;;
        esac
    done

    _bg_post-run
}

_bg_setup() {

    # exc_fn: executable path as called, which is likely a symlink
    exc_fn=$( basename -- "${BASH_SOURCE[0]}" )

    # src_dir: resolved absolute canonical path to the script dir
    src_dir=$( command python3 -c "from os import path; print(path.dirname(path.realpath('${BASH_SOURCE[0]}')))" ) \
        || return

    # Configure some common variables, functions, shell options, traps
    # - e.g. set nounset, extglob, umask
    source "${src_dir}/bgo_env_setup.sh"

    # Import required functions and check for scripts
    # - If PATH was reset (e.g. by sudo), borg-go may be harder to find, e.g. without
    #   setting up sudoers, or running from launchd/systemd/cron.
    # - However, we should still be able to find the supporting scripts in src_dir.
    # - Thus, borg-go should run fine as e.g. `sudo $(which borg-go)`.
    import_func -l _bg_args
    import_func -l bgo_chfile_sizes
    import_func -l bgo_ping_hc
    import_func -l bg_create
    import_func -l bg_prune
    import_func -l bg_check
    import_func -l bg_list
    bgo_scr_run --check bgo_prep_backupdir
}

# dependencies
_deps=( docsh err_msg vrb_msg physpath array_match run_vrb ignore_sigpipe rotate_logs )

if [[ $0 == "${BASH_SOURCE[0]}" ]]
then
    # Script was executed, not sourced
    trap 'exit' ERR

    # import dependencies
    # - import_func.sh should be symlinked somewhere on the PATH
    source import_func.sh
    import_func "${_deps[@]}"
    unset _deps

    # call main func
    # - NB, running as a_func || exit will *disable* any ERR trap set in a_func
    borg-go "$@"

else
    # This file is being sourced
    # - import_func should already be in the environment
    trap 'return' ERR

    import_func "${_deps[@]}"
    unset _deps
fi
