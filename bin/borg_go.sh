#!/usr/bin/env bash

# Inspired by the script in the official docs:
#   https://borgbackup.readthedocs.io/en/stable/quickstart.html#automating-backups
#
# by Andrew Davis (addavis@gmail.com)
# v0.1 (Jun 2022)

function print_usage { cat << EOF

  borg_go
  -------
  This script runs BorgBackup with the typical configuration and command options to
  create, prune, and check backups.

  Usage: borg_go [options] <command1 command2 ...>

  Commands:
    create  -> create a new backup archive in the default repository
    prune   -> remove old archives according to rules
    check   -> check integrity of repo and latest archive
    compact -> save space in repo; runs automatically after prune

  Options:
    -n | --dry-run -> run create and/or prune without changing the repo, to see what
                      would be backed up or removed. check and compact are not affected
                      by the dry-run option, but compact will not run automatically
                      after prune on a dry-run.

  Configuration:
    - set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
    - also set BORG_MNT_REQD=1 if necessary
    - to allow notifications and tracking using healthchecks.io, create the file
      healthchecks_UUID.txt in your BORG_CONFIG_DIR, which should contain the UUID
      of your healthchecks project (see https://healthchecks.io/)
EOF
}

# Configure some common variables, shell options, and functions
# - BASH_SOURCE (and 0) likely refer to symlink
# - exc_fn and exc_dir refer to the executable path as called, while
#   src_dir refers to the resolved absolute canonical path to the script dir
set -eE
BS0=${BASH_SOURCE[0]}
exc_fn=$(basename -- "$BS0")
exc_dir=$(dirname -- "$BS0")

src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
source "$src_dir/bgo_functions.sh"


# Parse arguments
[[ $# -eq 0 ]] && { print_usage; exit 0; }

# - keep track of create/prune/check to preserve order
cmd_array=()

while [ $# -gt 0 ]; do
    case $1 in
        create | test | prune | check | compact )
            cmd_array+=($1) ;;
        -n | --dry-run )
            dry_run="--dry-run" ;;
        -h | -help | --help )
            print_usage
            exit 0 ;;
        * )
            raise 2 "Unrecognized option: '$1'" ;;
    esac
    shift
done

# Check args and root
printf '%s\n' "${cmd_array[@]}" | grep -qxE -e "^(create|test|prune|check)\$"  \
    || raise w print_msg "No actions to perform, stay frosty"

# borg create requires root to read all files
# - generally a good idea to run as root when making changes to the repo otherwise
#   (i.e. anything beyond borg list or borg info), to prevent permissions issues in
#   the security and cache dirs.
[[ $(id -u) -eq 0 ]] || { raise 2 "root or sudo required."; }


# Environment variables
# - set in user ~/.bashrc or launchd plist: BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
# - unset, when running unencrypted locally or over a LAN: BORG_PASSPHRASE
# - cache and security should go in root's home if running as `sudo -EH`. This is to
#   prevent permissions problems when later running e.g. `borg info` as regular user
export BORG_CACHE_DIR=$HOME/.cache/borg
export BORG_SECURITY_DIR=$HOME/.config/borg/security

# If PATH was reset, the borg_go supporting scripts may not be found.
# - This may occur if running e.g. from launchd/systemd/cron as straight root rather
#   than sudo, or if not using SETENV or override secure_path in sudoers.
# - However, the executables (which can be symlinks to the scripts) should be in the
#   same directory as this one, so the following should still allow borg_go to be run
#   simply as e.g. `sudo -EH $(which borg_go)`, or as root with the relevant
#   environment variables set.
[[ $PATH == *"$exc_dir"* ]] || export PATH=$exc_dir:$PATH

# Other required scripts should be linked in e.g. ~/.local/bin
src_msg() { printf '%s\n' "$1 not found"$'\n'"you may need to run $src_dir/bgo_link.sh"; }

[[ -n $(command -v bgo_chfile_sizes) ]] \
    || raise 2 "$(src_msg bgo_chfile_sizes)"

[[ -n $(command -v bgo_ping_hc) ]] \
    || raise 2 "$(src_msg bgo_ping_hc)"

[[ -n $(command -v bgo_prep_backup) ]] \
    || raise 2 "$(src_msg bgo_prep_backup)"

[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
    && { [[ -n $(command -v bgo_check_mount) ]] \
             || raise 2 "$(src_msg bgo_check_mount)"; }


# Wipe out the log, then borg_logging.conf should append for this session
# - use cp to preserve ownership and file mode
log_fn=$BORG_CONFIG_DIR/borg_log.txt
[[ -s $log_fn ]] \
    && /bin/cp -pf "$log_fn" "$log_fn.1" && gzip -f "$log_fn.1"
printf '' > "$log_fn"


main() {

    ### --- Pre-run commands ---
    # mount repo if needed (erikson, mendeleev)
    [[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
        && { print_msg "Mounting backup repo"
            bgo_check_mount; }


    ### --- Main function ---
    for cmd in "${cmd_array[@]}"; do
        case "$cmd" in
            create  ) run_create ;;
            prune   ) run_prune  \
                        && { [[ -z ${dry_run-} ]] && run_compact; } ;;
            check   ) run_check ;;
            compact ) run_compact ;;
        esac
    done


    ### --- Post-run commands ---
    # unmount
    [[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
        && { print_msg "Unmounting backup repo"
             bgo_check_mount -u; }

    # chown log files owned by root to user login name, if running under sudo
    # - should only be necessary for newly created files
    def_lognm    # from bgo_functions: sets lognm, lognm_group, lognm_home

    find "$BORG_CONFIG_DIR" \( -name 'borg_log.txt*'                   \
                            -o -name 'borg_log_chfile*.txt'            \
                            -o -name 'borg_log_*-stats.txt'            \
                            -o -name 'borg_go_[ls]*d_out.txt*' \)      \
                            -user "$(id -un 0)"                        \
                            -exec chown "$lognm":"$lognm_group" '{}' \;

    # for fn in "$BORG_CONFIG_DIR"/borg_log{.txt*,_chfile*.txt,_*-stats.txt}  \
    #           "$BORG_CONFIG_DIR"/borg_go_{systemd,launchd}_out.txt*; do
    #     # some may not exist on test run, or some systems (Launchd vs Systemd)
    #     # - this is true even with nullglob, since brace expansion is not globbing
    #     [[ -f $fn ]] && chown "$lognm":"$lognm_group" "$fn"
    # done

    print_msg "borg_go done."
}


function run_create {

    ### --- Create Backup Archive ---
    # Backup e.g. system config and user files into an archive named after this machine
    local ping_msg

    print_msg "Starting backup ..."
    bgo_ping_hc start -m "borg ${dry_run-$'\b'} cmds: ${cmd_array[*]}"

    print_msg "- running pre-backup script"
    bgo_prep_backup

    if [[ -n ${dry_run-} ]]; then
        # dry-run affects item flags in log
        filters='x-'
    else
        filters='AMCE'
    fi

    # borg call
    print_msg "- calling borg create ${dry_run-$'\b'}"
    # - add -p for progress
    # - compression is lz4 by default
    # - using || to catch exit code 1, which borg uses for warnings
    #   note handle_borg_ec might add a warning to ping_msg

    borg create ${dry_run-} --list --filter "$filters" --stats               \
                --exclude-caches --exclude-if-present .nobackup              \
                --patterns-from "$BORG_CONFIG_DIR/borg_recursion_roots.txt"  \
                --patterns-from "$BORG_CONFIG_DIR/borg_patterns.txt"         \
                --info --show-rc ::'{hostname}-{now:%Y-%m-%dT%H.%M.%S}'      \
        || handle_borg_ec $?


    if [[ -n ${dry_run-} ]]; then
        # stats and changed files only supported without dry-run
        ping_msg+="no stats from create --dry-run"

    else
        # record file sizes for backed-up files
        print_msg "- recording file sizes of changed files"
        bgo_chfile_sizes

        # set aside stats block from log to prevent overwriting
        bc_stats_fn="$BORG_CONFIG_DIR/borg_log_create-stats.txt"
        grep -B 6 -A 10 'INFO Duration' "$log_fn" > "$bc_stats_fn.new"

        if [[ $(grep -c '^' "$bc_stats_fn.new") -eq 17 ]]; then

            print_msg "- recording stats block"
            /bin/mv -f "$bc_stats_fn.new" "$bc_stats_fn"
            ping_msg+="borg-create stats:"$'\n'
            ping_msg+=$(< "$bc_stats_fn")
        else
            ping_msg+="borg-create stats block from log not as expected: $BORG_CONFIG_DIR/$bc_stats_fn.new"
            print_msg WARNING "$ping_msg"
        fi
    fi

    # signal successful backup
    bgo_ping_hc success -m "$ping_msg"

    # Old code to read paths to backup into an array
    # This method has the advantage of shell globbing on the command line
    # incl_files=()
    # while IFS= read -r line; do

    #     # strip leading and trailing whitespace
    #     # - uses fancy ANSI-C quoting ($'') to get a tab character
    #     line="$(echo -n "$line" | sed -En $'s/^[ \t]*//; s/[ \t]*$//; p')"

    #     # ignore if empty or starting with #
    #     [[ -z $line || ${line:0:1} == \# ]] && continue

    #     incl_files+=($line)

    # done < "$BORG_CONFIG_DIR/borg_includes.txt"

    # borg create --info --show-rc                               \
    #     --list --filter 'AME' --stats                          \
    #     --exclude-caches --exclude-if-present .nobackup        \
    #     --exclude-from "$BORG_CONFIG_DIR/borg_excludes.txt"  \
    #     '::{hostname}-{now:%Y-%m-%dT%H.%M.%S}'                 \
    #     "${incl_files[@]}"
}

function run_prune {

    ### --- Prune Backup Archives ---
    # Remove old backups according to schedule
    local ping_msg

    print_msg "Starting prune ..."

    # borg command
    print_msg "- calling borg prune ${dry_run-$'\b'}"
    # - The '{hostname}-' prefix limits prune's operation to this machine's archives
    # - N.B. the keep rules don't operate exactly as you may expect, because they don't
    # count intervals in which there are no backups. E.g., if you only did 7 backups in
    # the last year, and they were all on different days, then --keep-daily 7 would keep
    # all those backups for the last year, not just the ones in the past week. Or, e.g.
    # if you only backup daily, and use --keep-hourly 24, the last 24 days of backups
    # will be kept. The keep-within rules are more like this, but not exactly...
    # - From the docs:
    #     + The --keep-within option takes an argument of the form “<int><char>”, where
    #       char is “H”, “d”, “w”, “m”, “y”. For example, --keep-within 2d means to keep
    #       all archives that were created within the past 48 hours.
    #     + The archives kept with this option do not count towards the totals specified
    #       by any other options.
    #     + E.g., --keep-daily 7 means to keep the latest backup on each day, up to 7
    #       most recent days with backups (days without backups do not count).
    # - If any rule is not fully satisfied, the earliest backup is retained.
    # - Weeks go from Monday to Sunday, so weekly backups may keep e.g. a Tuesday and a
    #   Sunday archive if that's all it has to choose from.
    # - See the docs for examples, but the finer details probably don't matter to us:
    # https://borgbackup.readthedocs.io/en/stable/usage/prune.html
    # - The following options should keep every archive within the last 14 days, and
    #   weekly archives for 2 weeks that have a backup before that, then similarly for 6
    #   monthly archives, and 3 yearly archives.

    borg prune ${dry_run-} --list --stats --prefix '{hostname}-' \
               --keep-within 14d                                 \
               --keep-weekly 2                                   \
               --keep-monthly 6                                  \
               --keep-yearly 3                                   \
               --info --show-rc ::

    if [[ -n ${dry_run-} ]]; then
        # stats only supported without dry-run
        ping_msg="no stats from prune --dry-run"$'\n'

    else
        # set aside stats block from log to prevent overwriting
        bp_stats_fn="$BORG_CONFIG_DIR/borg_log_prune-stats.txt"
        grep -B 2 -A 5 'INFO Deleted data' "$log_fn" > "$bp_stats_fn.new"

        if [[ $(grep -c '^' "$bp_stats_fn.new") -eq 8 ]]; then

            print_msg "- recording stats block"
            /bin/mv -f "$bp_stats_fn.new" "$bp_stats_fn"
            ping_msg="borg-prune stats:"$'\n'
            ping_msg+=$(< "$bp_stats_fn")
        else
            ping_msg="borg-prune stats block from log not as expected:"$'\n'
            ping_msg+="$BORG_CONFIG_DIR/$bp_stats_fn.new"$'\n'
            print_msg WARNING "$ping_msg"
        fi
    fi

    # signal successful prune
    bgo_ping_hc success -m "$ping_msg"
}

function run_check {

    ### --- Check Repo and Archive(s) ---
    # Examine backup repo and most recent archive to ensure validity
    print_msg "Starting check ..."

    borg check --last 1 --prefix '{hostname}-' \
               --info --show-rc ::
    # borg check --last 1 --prefix '{hostname}-' --info --show-rc --progress ::
}

function run_compact {

    ### --- Compact Repo ---
    # actually free repo disk space by compacting segments
    # - this is most useful after delete and prune operations
    print_msg "Starting compact ..."

    borg compact --threshold 1 \
                 --info --show-rc ::
}

function handle_borg_ec {
    # Handle non-zero exit codes from borg
    # - borg exits with ec=1 for warnings, which shouldn't
    #   bring down the whole script, but should be reported
    ec=$1

    if [[ $ec -eq 1 ]]; then
        # relay borg warning
        ping_msg="In ${FUNCNAME[1]}, borg exited with code 1; WARNINGs from borg_log.txt:"$'\n'
        ping_msg+=$(grep WARNING "$log_fn")$'\n'
        print_msg WARNING "$ping_msg"
    else
        # trigger the trap error handling
        (exit $ec)
    fi
}


# Now that functions are defined, run main()
main
