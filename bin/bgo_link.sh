#!/usr/bin/env bash

# This script creates symlinks to relevant scripts and config files associated
# with the borg_go project.

# v0.1 (Jun 2022) by Andrew Davis (addavis@gmail.com)

function print_usage { cat << EOF

    $(basename $0)
    --------
    This script creates symlinks to relevant scripts and config files associated
    with the borg_go project. By default, scripts are linked in ~/.local/bin/ and config
    files are linked in BORG_CONFIG_DIR, which is usually ~/.config/borg/.

    Usage: $(basename $0) [options]

    Options:
        -b | --bin_dir )      local bin dir (default ~/.local/bin)
        -c | --config_repo )  borg config repo (default ../../Sync/Config/borg)
        -s | --script_repo )  borg scripts repo (default ../../Sync/Code/Backup/borg_scripts/bin)
        -m | --mach_name )    machine name (default from `hostname -s`)
        -o | --mach_os )      machine OS (default from `uname -s`)
        -n | --dry-run )      show what would be done, don't perform actions

EOF
}

# Configure some common variables, shell options, and functions
set -eE
BS0="${BASH_SOURCE[0]}"
exc_fn=$(basename -- "$BS0")
exc_dir=$(dirname -- "$BS0")

src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
source "$src_dir/bgo_functions.sh"


# Default parameter values
local_bin_dir=~/.local/bin
maybe=''

[[ -n ${BORG_CONFIG_DIR-} ]] || raise 2 "BORG_CONFIG_DIR not set"

borg_scripts_repo="../../Sync/Code/Backup/borg_go/bin"
borg_config_repo="../../Sync/Config/borg"

def_mach_id     # mach_name and mach_os from bgo_functions


# Parse arguments
function arg_reqd {
    # confirm OPTARG got a non-null value
    [[ -n ${OPTARG-} ]] || raise 2 "Argument required for --$OPT"
}

while getopts 'nb:c:s:m:o:-:' OPT; do

    if [[ $OPT == '-' ]]; then
        # long option: reformulate OPT and OPTARG
        OPT=${OPTARG%%=*}       # extract long option name
        OPTARG=${OPTARG#$OPT}   # extract long option argument (may be empty)
        OPTARG=${OPTARG#=}      # and strip the '='
    fi

    case $OPT in
        b | bin_dir )      arg_reqd && local_bin_dir=$OPTARG ;;
        c | config_repo )  arg_reqd && borg_config_repo=$OPTARG ;;
        s | script_repo )  arg_reqd && borg_scripts_repo=$OPTARG ;;
        m | mach_name )    arg_reqd && mach_name=$OPTARG ;;
        o | mach_os )      arg_reqd && mach_os=$OPTARG ;;
        n | dry-run )      maybe=echo ;;
        ??* )    raise 2 "Unknown option --$OPT" ;;
        ? )      exit 2 ;;  # bad short option (error reported via getopts)
    esac
done
shift $((OPTIND-1))  # remove parsed options and args


echo "Setting up and making links..."
$maybe set -vx  # verbose output of shell commands

# Link scripts
# - working in ~/.local/bin/ by default
$maybe /bin/mkdir -p "$local_bin_dir"
cd "$local_bin_dir"
[[ -d $borg_scripts_repo ]] || raise 2 "borg_scripts_repo not found: '$borg_scripts_repo'"

$maybe ln -s "$borg_scripts_repo/borg_go.sh" borg_go
$maybe ln -s "$borg_scripts_repo/bgo_check_mount.sh" bgo_check_mount
$maybe ln -s "$borg_scripts_repo/bgo_chfile_sizes.sh" bgo_chfile_sizes
$maybe ln -s "$borg_scripts_repo/bgo_prep_backup.sh" bgo_prep_backup
$maybe ln -s "$borg_scripts_repo/bgo_ping_hc.sh" bgo_ping_hc

# check to make sure scripts are on PATH
$maybe [[ -n $(command -v borg_go) ]] || raise 2 "borg_go not on path"


# Link config files
# - work in config dir, usually ~/.config/borg/
$maybe /bin/mkdir -p "$BORG_CONFIG_DIR"
cd "$BORG_CONFIG_DIR"
[[ -d $borg_config_repo ]] || raise 2 "borg_config_repo not found: '$borg_config_repo'"

$maybe ln -s "$borg_config_repo/borg_logging_${mach_name}_${mach_os}.conf" borg_logging.conf
$maybe ln -s "$borg_config_repo/borg_recursion_roots_${mach_name}_${mach_os}.txt" borg_recursion_roots.txt
$maybe ln -s "$borg_config_repo/healthchecks_UUID_${mach_name}.txt" healthchecks_UUID.txt

# patterns may only follow OS
[[ -s "$borg_config_repo/borg_patterns_${mach_name}_${mach_os}.txt" ]]       \
    && pat_fn="$borg_config_repo/borg_patterns_${mach_name}_${mach_os}.txt"  \
    || pat_fn="$borg_config_repo/borg_patterns_${mach_os}.txt"

$maybe ln -s "$pat_fn" borg_patterns.txt

$maybe set +vx
