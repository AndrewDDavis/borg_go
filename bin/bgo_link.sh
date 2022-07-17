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

EOF
}

# Configure some common variables, shell options, and functions
src_bn=$(basename -- "${BASH_SOURCE[0]}")
src_dir=$(dirname -- "$(readlink "${BASH_SOURCE[0]}")")

source "$src_dir/bgo_functions.sh"


# Default parameter values
local_bin_dir=~/.local/bin
[[ -n ${BORG_CONFIG_DIR-} ]] || raise 2 "BORG_CONFIG_DIR not set"

borg_scripts_repo="../../Sync/Code/Backup/borg_go/bin"
borg_config_repo="../../Sync/Config/borg"

def_mach_id     # mach_name and mach_os from bgo_functions


# Parse arguments
function arg_reqd {
    # confirm OPTARG got a non-null value
    [[ -n ${OPTARG-} ]] || raise 2 "Argument required for --$OPT"
}

while getopts 'b:c:s:m:o:-:' OPT; do

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
        ??* )    raise 2 "Unknown option --$OPT" ;;
        ? )      exit 2 ;;  # bad short option (error reported via getopts)
    esac
done
shift $((OPTIND-1))  # remove parsed options and args


echo "Setting up and making links..."
set -vx  # verbose output of shell commands

# Link scripts
# - working in ~/.local/bin/ by default
/bin/mkdir -p "$local_bin_dir"
cd "$local_bin_dir"
[[ -d $borg_scripts_repo ]] || raise 2 "borg_scripts_repo not found: '$borg_scripts_repo'"

ln -s "$borg_scripts_repo/borg_go.sh" borg_go
ln -s "$borg_scripts_repo/bgo_check_mount.sh" bgo_check_mount
ln -s "$borg_scripts_repo/bgo_chfile_sizes.sh" bgo_chfile_sizes
ln -s "$borg_scripts_repo/bgo_prep_backup.sh" bgo_prep_backup
ln -s "$borg_scripts_repo/bgo_ping_hc.sh" bgo_ping_hc

# check to make sure scripts are on PATH
[[ -n $(command -v borg_go) ]] || raise 2 "borg_go not on path"


# Link config files
# - work in config dir, usually ~/.config/borg/
/bin/mkdir -p "$BORG_CONFIG_DIR"
cd "$BORG_CONFIG_DIR"
[[ -d $borg_config_repo ]] || raise 2 "borg_config_repo not found: '$borg_config_repo'"

ln -s "$borg_config_repo/borg_logging_${mach_name}_${mach_os}.conf" borg_logging.conf
ln -s "$borg_config_repo/borg_patterns_${mach_name}_${mach_os}.txt" borg_patterns.txt
ln -s "$borg_config_repo/borg_recursion_roots_${mach_name}_${mach_os}.txt" borg_recursion_roots.txt
ln -s "$borg_config_repo/healthchecks_UUID_${mach_name}.txt" healthchecks_UUID.txt

set +vx
