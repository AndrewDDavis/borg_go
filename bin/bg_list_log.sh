# shellcheck shell=bash
bg_list() {

    # check for list cmd
    if array_match cmd_array list
    then
        [[ ${#cmd_array[*]} == 1 ]] \
            || err_msg -d w "ignoring commands other than list"

        [[ -v 'bgl_args[*]' ]] \
            || bgl_args=( --consider-checkpoints --last=10 "$repo_uri" )

        vrb_msg 2 "running list ${bgl_args[*]}"

        BORG_LOGGING_CONF='' "$borg_cmd" list "${bgl_args[@]}"

    else
        return 1
    fi
}

bg_log() {

    # check for log cmd
    if array_match cmd_array log
    then
        [[ ${#cmd_array[*]} == 1 ]] \
            || err_msg -d w "ignoring commands other than list"

        command less -iJMR \
            --buffers=1024 --jump-target=.2 --tabs=4 --shift=4 --use-color \
            "${bgl_args[@]}" \
            "$log_fn"

    else
        return 1
    fi
}
