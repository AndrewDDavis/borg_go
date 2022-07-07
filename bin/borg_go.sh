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

# Robust options
set -o nounset    # fail on unset variables
set -o errexit    # fail on non-zero return values
set -o errtrace   # make shell functions, subshells, etc obey ERR trap
set -o pipefail   # fail if any piped command fails
shopt -s extglob  # allow extended pattern matching

# print_msg function
# - prints log-style messages
# - usage: print_msg ERROR "the script had a problem"
script_bn=$(basename -- "$0")

function print_msg {
    local msg_type=INFO

    [[ $1 == @(DEBUG|INFO|WARNING|ERROR) ]] \
        && { msg_type=$1; shift; }

    printf "%s %s %s\n" "$(date)" "$script_bn [$msg_type]" "$*" >&2
}

# handle interrupt and exceptions
trap 'raise 2 "$script_bn was interrupted${FUNCNAME:+ (function $FUNCNAME)}"' INT TERM
trap "$(cat << 'EOF'
ec=$?
ping_msg="Exception $ec in $0 at line $LINENO${FUNCNAME:+ (function stack: ${FUNCNAME[@]})}"
hc_ping failure -m "$ping_msg"
raise $ec "$ping_msg"
EOF
)" ERR

# raise function
# - prints error message and exits with code
# - usage: raise 2 "valueError: foo should not be 0"
#          raise w "file missing, that's not great but OK"
function raise {
    local msg_type=ERROR
    local ec=${1:?"raise function requires exit code"}
    [[ $ec == w ]] && { msg_type=WARNING; ec=0; }

    print_msg "$msg_type" "${2:?"raise function requires message"}"
    exit $ec
}

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


# PATH: If user can't or doesn't want to use SETENV or override secure_path in sudoers,
# PATH may have been reset, and the supporting scripts of the borg_go_script package
# won't be found. However, these should be in the same directory, so this allows borg_go
# to be run as `sudo -EH $(which borg_go)` under those circumstances.
script_dn=$(dirname -- "$0")
export PATH=$script_dn:$PATH


# Other required scripts, should be linked in e.g. ~/.local/bin
[[ -n $(command -v borg_chfile_sizes) ]] \
    || raise 2 "borg_chfile_sizes not found"

[[ -n $(command -v hc_ping) ]] \
    || raise 2 "hc_ping not found"

[[ -n $(command -v borg_pre-backup) ]] \
    || raise 2 "borg_pre-backup not found"

[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
    && { [[ -n $(command -v borg_mount-check) ]] || raise 2 "borg_mount-check not found"; }


# Environment variables
# - set in user ~/.bashrc: BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF
# - unset, when running unencrypted locally or over a LAN: BORG_PASSPHRASE
# - cache and security should go in root's home if running as `sudo -EH`. This is to
#   prevent permissions problems when later running e.g. `borg info` as regular user
export BORG_CACHE_DIR=$HOME/.cache/borg
export BORG_SECURITY_DIR=$HOME/.config/borg/security

# Umask -- no write for group, no perms for other
umask 027

# Wipe out the log, then borg_logging.conf should append for this session
log_fn=$BORG_CONFIG_DIR/borg_log.txt
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
        function rtn { return $1; }
        rtn $ec
    fi
}

function run_create {

    ### --- Create Backup Archive ---
    # Backup e.g. system config and user files into an archive named after this machine
    local ping_msg

    print_msg "Starting backup ..."
    hc_ping start -m "borg cmds: ${cmd_array[*]}"

    print_msg "- running pre-backup script"
    borg_pre-backup

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
        borg_chfile_sizes

        # set aside stats block from log to prevent overwriting
        bc_stats_fn="$BORG_CONFIG_DIR/borg_stats_create.txt"
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
    hc_ping success -m "$ping_msg"

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

    # from borgmatic:
    # borg prune --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 3 \
    #            --prefix '{hostname}-' --debug --show-rc hud@nemo:/mnt/backup/borgbackup_squamish_macos_repo

    # borg command
    # - The '{hostname}-' prefix limits prune's operation to this machine's archives

    borg prune --list --stats --prefix '{hostname}-' \
               --keep-hourly 24 --keep-daily 7       \
               --keep-weekly 4 --keep-monthly 6      \
               --keep-yearly 3                       \
               --info --show-rc ::

    # set aside stats block from log to prevent overwriting
    bp_stats_fn="${BORG_CONFIG_DIR}/borg_stats_prune.txt"
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
    hc_ping success -m "$ping_msg"
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
    print_msg "Compacting repository ..."

    borg compact --threshold 1 \
                 --info --show-rc ::
}


### --- Pre-run commands ---
# mount repo if needed (erikson, mendeleev)
[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] && borg_mount-check


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
[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] && borg_mount-check -u

# chown log files
# - should only be necessary for newly created files, but shouldn't hurt
luser=$(logname)  # login name of user running sudo
luser_group=$(id -gn "$luser")

if [[ $luser != $(id -un 0) ]]; then
    for fn in "$BORG_CONFIG_DIR"/{borg_log.txt,borg_chfile*.txt,borg_stats*.txt}; do
        # some may not exist yet after test run
        [[ -e $fn ]] && chown "$luser:$luser_group" $fn
    done
fi
