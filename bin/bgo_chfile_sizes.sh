#!/usr/bin/env bash

# find backed-up files from the latest backup archive process from borg
# and sort by size
#
# - reads and writes to ~/.config/borg, in the logged in user's home
# - requires recent borgmatic backup run with --files, or recent borg
#   backup run with --info --list --filter=AME...

# v0.1 (Jun 2022) by Andrew Davis (addavis@gmail.com)

# Configure some common variables, shell options, and functions
src_bn=$(basename -- "${BASH_SOURCE[0]}")
src_dir=$(dirname -- "$(readlink "${BASH_SOURCE[0]}")")

source "$src_dir/bgo_functions.sh"


# requires root to reliably stat all files
[[ $(id -u) -eq 0 ]] || { print_msg ERROR "root or sudo required."; exit 2; }

# find config dir based on logged-in user name (when running with sudo)
def_luser  # luser, luser_group, luser_home from bgo_functions

if [[ -z $BORG_CONFIG_DIR ]]; then
    BORG_CONFIG_DIR="${luser_home}/.config/borg"
fi

borg_logfile=borg_log.txt
chf_fn=borg_log_chfiles.txt
errf_fn=borg_errfiles.txt
fs_fn=borg_log_chfile_sizes.txt

cd "$BORG_CONFIG_DIR" \
    || { print_msg ERROR "could not cd to config dir: '$BORG_CONFIG_DIR'"; exit 2; }

[[ -r $borg_logfile ]] \
    || { print_msg ERROR "could not read logfile: '$borg_logfile'"; exit 2; }

# check for any error files
sed -En 's/^.*INFO E (.*)/\1/ p' $borg_logfile >"${errf_fn}.new"
n_files=$(grep -c '^' "${errf_fn}.new")
if (( $n_files == 0 )); then
    # no errors, as expected
    /bin/rm "${errf_fn}.new"
else
    /bin/mv "${errf_fn}.new" "$errf_fn"
    print_msg WARNING "Error files found, see $errf_fn:"
    head "$errf_fn"
fi

# parse log file to extract only file paths of changed files
sed -En 's/^.*INFO [AMC] (.*)/\1/ p' $borg_logfile >"${chf_fn}.new"

n_files=$(grep -c '^' "${chf_fn}.new")
if [[ $n_files =~ [^0-9] ]]; then
    print_msg ERROR "expected non-negative integer for n_files: $n_files"
    exit 2

elif [[ $n_files -eq 0 ]]; then
    print_msg WARNING "no filenames found in log"
    /bin/rm "${chf_fn}.new"
    exit 0

else
    /bin/mv "${chf_fn}.new" "$chf_fn"
fi

# find file sizes for changed files
# - du's "cannot access" messages occur for moved/deleted files
# - this works as long as there are no newlines in filenames (no --files0-from in BSD du)
# - for a large number of files, you may get argument list too long with
#   du -hsc $(< $chf_fn)
# - also, du doesn't read from stdin under BSD, so getting the total (-c) is tricky,
#   might require awk

printf '%s\0' $(< "$chf_fn") | xargs -0 du -hs -- 2>/dev/null >"${fs_fn}.new"

n_sizes=$(grep -c '^' "${fs_fn}.new")

# ensure du output was as expected
if [[ $n_sizes =~ [^0-9] ]]; then

    print_msg ERROR "expected non-negative integer for n_sizes: $n_sizes"
    exit 2

elif [[ $n_sizes -eq 0 ]]; then

    print_msg ERROR "no sizes found by du: '${PWD}/${fs_fn}.new'"
    exit 2
fi

/bin/mv "${fs_fn}.new" "$fs_fn"
print_msg "Files and sizes output to ${PWD}/${fs_fn}."
print_msg "Found $n_files filenames, reported sizes on $n_sizes"

# output files sorted by size
# -h handles human-readable chars for K, M, G, etc
# sed prepends spaces to each line
print_msg "Largest 12:"
sort -rh "$fs_fn" | head -n 12 | sed 's/^/    /'

# clean up
# [[ $1 == --noclean ]] || /bin/rm $chf_fn $fs_fn

# chown instead
chown "$luser":"$luser_group" "$chf_fn" "$fs_fn"
# chmod 0640 "$chf_fn" "$fs_fn"
