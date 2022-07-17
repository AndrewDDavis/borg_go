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

  Usage: borg_go <commands ...>

  Commands:
    create  -> create a new backup archive in the default repository
    test    -> run create with --dry-run to see what would be backed up
    prune   -> remove old archives according to rules
    check   -> check integrity of repo and latest archive
    compact -> save space in repo; runs automatically after prune

  Configuration:
    - set env vars BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
    - also set BORG_MNT_REQD=1 if necessary
    - to allow notifications and tracking using healthchecks.io, create the file
      healthchecks_UUID.txt in your BORG_CONFIG_DIR, which should contain the UUID
      of your healthchecks project (see https://healthchecks.io/)
EOF
}

# Configure some common variables, shell options, and functions
src_bn=$(basename -- "${BASH_SOURCE[0]}")
src_dir=$(dirname -- "${BASH_SOURCE[0]}")

source "${src_dir}"/bgo_functions.sh


# Parse arguments
[[ $# -eq 0 ]] && { print_usage; exit 0; }

# - keep track of create/prune/check to preserve order
cmd_array=()

while [ $# -gt 0 ]; do
    case $1 in
        create | test | prune | check | compact )
            cmd_array+=($1) ;;
        -h | -help | --help )
            print_usage
            exit 0 ;;
        * )
            raise 2 "Unrecognized option: '$1'" ;;
    esac
    shift
done

# Check args
if ! printf '%s\n' "${cmd_array[@]}" | grep -qxE -e '^(create|test|prune|check)$'; then

    print_msg "No actions to perform, stay frosty"
    exit 0

# elif printf '%s\n' "${cmd_array[@]}" | grep -qFx -e 'create'; then
else
    # create requires root to read all files
    # - generally a good idea to run as root when accessing the repo otherwise
    [[ $(id -u) -eq 0 ]] || { raise 2 "root or sudo required."; }
fi


# Environment variables
# - set in user ~/.bashrc or launchd plist: BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
# - unset, when running unencrypted locally or over a LAN: BORG_PASSPHRASE
# - cache and security should go in root's home if running as `sudo -EH`. This is to
#   prevent permissions problems when later running e.g. `borg info` as regular user
export BORG_CACHE_DIR=$HOME/.cache/borg
export BORG_SECURITY_DIR=$HOME/.config/borg/security

# PATH may have been reset, and the supporting scripts of the borg_go package won't be
# found. This may happen if running e.g. from launchd or cron as straight root, rather
# than sudo, or if user can't or doesn't want to use SETENV or override secure_path in
# sudoers. However, the scripts should be in the same directory as this one, so the
# following should allow borg_go to be run as `sudo -EH $(which borg_go)` under those
# circumstances, or as root with the relevant environment variables set.
[[ $PATH == *"$src_dir"* ]] || export PATH=$src_dir:$PATH

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
# - try to preserve ownership and file mode
log_fn=$BORG_CONFIG_DIR/borg_log.txt
/bin/cp -pf "$log_fn" "${log_fn}.1" && gzip -f "${log_fn}.1"
printf '' > "$log_fn"


function handle_borg_ec {
    # Handle non-zero exit codes from borg
    # - borg exits with ec=1 for warnings, which shouldn't
    #   bring down the whole script, but should be reported
    ec=$1

    if [[ $ec -eq 1 ]]; then
        # relay borg warning
        ping_msg="In ${FUNCNAME[1]}, borg exited with code 1; WARNINGs from borg_log.txt:"$'\n'
        ping_msg+=$(grep WARNING "$log_fn")$'\n\n'
        print_msg WARNING "$ping_msg"
    else
        # trigger the trap error handling
        (exit $ec)
    fi
}

function run_create {

    ### --- Create Backup Archive ---
    # Backup e.g. system config and user files into an archive named after this machine
    local ping_msg

    print_msg "Starting backup ..."
    bgo_ping_hc start -m "borg cmds: ${cmd_array[*]}"

    print_msg "- running pre-backup script"
    bgo_prep_backup

    # use --dry-run if test was called
    if printf '%s\n' "${cmd_array[@]}" | grep -qFx -e 'test'; then
        dry_run="--dry-run"

        # dry-run affects item flags in log
        filters='x-'
    else
        filters='AMCE'
    fi

    # borg call
    print_msg "- calling borg ${dry_run-$'\b'}"
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
        ping_msg+="--dry-run"

    else
        # record file sizes for backed-up files
        print_msg "- recording file sizes of changed files"
        bgo_chfile_sizes

        # set aside stats block from log to prevent overwriting
        bc_stats_fn="$BORG_CONFIG_DIR/borg_log_create-stats.txt"
        grep -B 6 -A 10 'INFO Duration' "$log_fn" > "${bc_stats_fn}.new"

        if [[ $(grep -c '^' "${bc_stats_fn}.new") -eq 17 ]]; then

            print_msg "- recording stats block"
            /bin/mv "${bc_stats_fn}.new" "$bc_stats_fn"
            ping_msg+=$(< "$bc_stats_fn")
        else
            ping_msg+="stats block from log not as expected: $BORG_CONFIG_DIR/${bc_stats_fn}.new"
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

    # done < "${BORG_CONFIG_DIR}/borg_includes.txt"

    # borg create --info --show-rc                               \
    #     --list --filter 'AME' --stats                          \
    #     --exclude-caches --exclude-if-present .nobackup        \
    #     --exclude-from "${BORG_CONFIG_DIR}/borg_excludes.txt"  \
    #     '::{hostname}-{now:%Y-%m-%dT%H.%M.%S}'                 \
    #     "${incl_files[@]}"
}

function run_prune {

    ### --- Prune Backup Archives ---
    # Remove old backups according to schedule
    local ping_msg

    print_msg "Starting prune ..."

    # TODO: add test/dry-run option to run `prune -v --list --dry-run ...`
    #       deal with missing stats block for dry-run as in create

    # borg command
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

    borg prune --list --stats --prefix '{hostname}-' \
               --keep-within 14d                     \
               --keep-weekly 2                       \
               --keep-monthly 6                      \
               --keep-yearly 3                       \
               --info --show-rc ::

    # set aside stats block from log to prevent overwriting
    bp_stats_fn="${BORG_CONFIG_DIR}/borg_log_prune-stats.txt"
    grep -B 2 -A 5 'INFO Deleted data' "$log_fn" > "${bp_stats_fn}.new"

    if [[ $(grep -c '^' "${bp_stats_fn}.new") -eq 8 ]]; then

        print_msg "- recording stats block"
        /bin/mv "${bp_stats_fn}.new" "$bp_stats_fn"
        ping_msg=$(< "$bp_stats_fn")
    else
        ping_msg="stats block from log not as expected: ${BORG_CONFIG_DIR}/${bp_stats_fn}.new"
        print_msg WARNING "$ping_msg"
    fi

    # signal successful backup
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


### --- Pre-run commands ---
# mount repo if needed (erikson, mendeleev)
[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
    && { print_msg "Mounting backup repo"
         bgo_check_mount; }


### --- Main function ---
for cmd in "${cmd_array[@]}"; do
    case "$cmd" in
        test    ) run_create --dry-run ;;
        create  ) run_create ;;
        prune   ) run_prune && run_compact ;;
        check   ) run_check ;;
        compact ) run_compact ;;
    esac
done


### --- Post-run commands ---
# unmount
[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
    && { print_msg "Unmounting backup repo"
         bgo_check_mount -u; }

# chown log files, if running under sudo
# - should only be necessary for newly created files, but shouldn't hurt
def_luser  # luser, luser_group, luser_home from bgo_functions

if [[ $luser != $(id -un 0) ]]; then
    for fn in "$BORG_CONFIG_DIR"/{borg_log.txt*,borg_log_chfile*.txt,borg_log_*-stats.txt,borg_go_systemd_out.log*}; do
        # some may not exist yet after test run
        # - this is true even with nullglob, since brace expansion is not actually
        #   globbing
        [[ -e $fn ]] && chown "$luser":"$luser_group" $fn
    done
fi

print_msg "borg_go done."
