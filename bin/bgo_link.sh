#!/usr/bin/env bash

# This script creates symlinks to relevant scripts and config files associated
# with the borg-go project.

# v0.1 (Jun 2022) by Andrew Davis (addavis@gmail.com)

function print_usage { cat << EOF

    $(basename $0)
    --------
    This script creates symlinks to relevant scripts and config files associated
    with the borg-go project. By default, scripts are linked in ~/.local/bin/ and config
    files are linked in BORG_CONFIG_DIR, which is usually ~/.config/borg/.

    Usage: $(basename $0) [-n | --dry-run] [options]

    Options:
        -b | --bin_dir )      local bin dir (default ~/.local/bin)
        -c | --config_repo )  borg config repo (default ../../Sync/Config/borg)
        -s | --script_repo )  borg scripts repo (default ../../Sync/Code/Backup/borg_go/bin)
        -m | --mach_name )    machine name (default from `hostname -s`)
        -o | --mach_os )      machine OS (default from `uname -s`)
        -n | --dry-run )      show what would be done, don't perform actions

EOF
}

[[ $1 == -h || $1 == -help || $1 == --help ]] && { print_usage; exit 0; }


# Configure some common variables, shell options, and functions
set -eE

src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('${BASH_SOURCE[0]}')))")
source "$src_dir/bgo_env_setup.sh"


# Default parameter values
bin_dir=~/.local/bin
borg_scripts_repo="../../Sync/Code Projects/Backup/borg_go/bin"
borg_config_repo="../../Sync/Config/borg"

maybe=''

[[ -n ${BORG_CONFIG_DIR:-} ]] \
    || { err_msg -d 2 "BORG_CONFIG_DIR not set"; exit; }


# Parse arguments
function arg_reqd {
    # confirm OPTARG got a non-null value
    [[ -n ${OPTARG-} ]] \
        || { err_msg -d 2 "Argument required for --$OPT"; exit; }
}

while getopts 'nb:c:s:m:o:-:' OPT
do
    if [[ $OPT == '-' ]]
    then
        # long option: reformulate OPT and OPTARG
        OPT=${OPTARG%%=*}       # extract long option name
        OPTARG=${OPTARG#$OPT}   # extract long option argument (may be empty)
        OPTARG=${OPTARG#=}      # and strip the '='
    fi

    case $OPT in
        ( b | bin_dir )
            arg_reqd && bin_dir=$OPTARG
        ;;
        ( c | config_repo )
            arg_reqd && borg_config_repo=$OPTARG
        ;;
        ( s | script_repo )
            arg_reqd && borg_scripts_repo=$OPTARG
        ;;
        ( m | mach_name )
            arg_reqd && mach_name=$OPTARG
        ;;
        ( o | mach_os )
            arg_reqd && mach_os=$OPTARG
        ;;
        ( n | dry-run )
            maybe='echo would '
        ;;
        ( ??* )
            err_msg -d 2 "Unknown option --$OPT"
            exit
        ;;
        ( '?' )
            # bad short option (error reported via getopts)
            exit 2
        ;;
    esac
done
shift $(( OPTIND-1 ))  # remove parsed options and args


echo "Setting up and making links..."
${maybe}set -vx  # verbose output of shell commands

# Link scripts
# - working in ~/.local/bin/ by default
[[ -d $bin_dir ]] \
    || ${maybe}/bin/mkdir -p "$bin_dir"
cd "$bin_dir"

[[ -d $borg_scripts_repo ]] \
    || { err_msg -d 2 "borg_scripts_repo not found: '$borg_scripts_repo'"; exit; }
${maybe}ln -sf "$borg_scripts_repo/borg-go.sh" borg-go

# check to make sure scripts are on PATH
[[ -n $( command -v borg-go ) ]] \
    || { [[ -n ${maybe} ]] || { err_msg -d 2 "borg-go not on path"; exit; }; }


# Create symlinks
# - borg-go should find the supporting scripts within the scripts_repo dir,
#   we just need to link config files

# Link config files
# - work in config dir, usually ~/.config/borg/
[[ -d $BORG_CONFIG_DIR ]] \
    || ${maybe}/bin/mkdir -p "$BORG_CONFIG_DIR"
cd "$BORG_CONFIG_DIR"

# - linking from repo dir
[[ -d $borg_config_repo ]] \
    || { err_msg -d 2 "borg_config_repo not found: '$borg_config_repo'"; exit; }


_chk_lnk_cnf() {
    # link file if it exists and is non-empty

    [[ -s $1 ]] && {
        ${maybe}ln -sf "$1" "$2"
        return 0
    } || {
        return 1
    }
}


# Healthchecks UUID is always unique to the machine
# - mach_name and mach_os are set in bgo_env_setup
_chk_lnk_cnf "$borg_config_repo/healthchecks_UUID-${mach_name}"  healthchecks_UUID

# The logging.conf file is a single file identified by BORG_LOGGING_CONF
log_fn=$borg_config_repo/borg_logging-${mach_os}_${mach_name}.conf

_chk_lnk_cnf "$log_fn" borg_logging.conf  || {
    _chk_lnk_cnf "${log_fn/_${mach_name}/}" borg_logging.conf
}

# Pattern config files may follow OS only, or have additional machine-specific config
# - both should be linked, if they exist, but the machine-specific should come first
#   to allow overrides.
pat_fn=$borg_config_repo/borg_patterns-${mach_os}_${mach_name}.txt

_chk_lnk_cnf  "$pat_fn"                  borg_patterns_0.txt
_chk_lnk_cnf "${pat_fn/_${mach_name}/}"  borg_patterns_1.txt


rec_fn=$borg_config_repo/borg_recursion_roots-${mach_os}_${mach_name}.txt

_chk_lnk_cnf  "$rec_fn"                  borg_recursion_roots_0.txt
_chk_lnk_cnf "${rec_fn/_${mach_name}/}"  borg_recursion_roots_1.txt


${maybe}set +vx
