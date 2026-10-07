# shellcheck shell=bash
bg_list_log_status() {

    if array_match cmd_array list
    then
        _ign_cmd ${#cmd_array[*]} list
        _bg_list

    elif array_match cmd_array log
    then
        _ign_cmd ${#cmd_array[*]} log
        _bg_log

    elif array_match cmd_array status
    then
        _ign_cmd ${#cmd_array[*]} status
        _bg_status
    else
        return 1
    fi
}

_ign_cmd() {

    # _ign_cmd no cmd
    if [[ $1 -ne 1 ]]
    then
        el_msg w "ignoring commands other than $2"
    fi
}

_bg_list() {

    [[ -v 'bgl_args[*]' ]] \
        || bgl_args=( --consider-checkpoints --last=10 "$repo_uri" )

    vrb_msg 2 "running list ${bgl_args[*]}"

    BORG_LOGGING_CONF='' "$borg_cmd" list "${bgl_args[@]}"
}

_bg_log() {

    command less -iJMR \
        --buffers=1024 --jump-target=.2 --tabs=4 --shift=4 --use-color \
        "${bgl_args[@]}" \
        "$log_fn"
}

_bg_status() {

    [[ -n $( command -v systemctl ) ]] \
            || { el_msg 4 "systemctl command not found"; exit; }

    # refer to systemctl man page under "EXIT STATUS"
    # - NB, borg-go is usually not active, just waiting to be triggered by
    #   the timer (i.e. it's a static unit).
    # - can use is-active, then check for EC=0, 3, or 4
    local -i ec
    local show_out status_msgs=( "" )
    if systemctl is-active --quiet borg-go.service
    then
        printf >&2 '%s\n' "The borg-go service is currently active"
    else
        ec=$?
        if (( ec == 4 ))
        then
            el_msg 4 "borg-go.service not found by systemctl"
            exit

        elif (( ec == 3 ))
        then
            # typical; get more info
            show_out=$( systemctl show borg-go.service )
            # for systemctl show vars, refer to 'man org.freedesktop.systemd1'
            # ExecMainStartTimestampMonotonic : 0 if not run since reboot, other integer
            # UnitFileState : enabled, disabled, static, masked, ...
            # ActiveState   : active, inactive, failed, activating, ...
            # Result : execution result of last run: success, resources, timeout, exit-code, signal, ...
            # ExecMainCode : 1 = exited, 2 = killed, 3 = dumped
            # ExecMainStatus : if EMC = 1, this is the standard Linux exit code
            # ExecMainStartTimestamp : main process start and
            # ExecMainExitTimestamp  : ... stop times

            if ! grep 'UnitFileState=static' >/dev/null <<< "$show_out"
            then
                el_msg 5 "borg-go.service is not a static unit; aborting"
                exit

            elif grep 'ExecMainStartTimestampMonotonic=0' >/dev/null <<< "$show_out"
            then
                status_msgs+=( "  The borg-go service has not run since the last reboot." )

            else
                local v_as v_res v_emc v_ems v_est v_eet
                v_as=$( sed -En 's/^ActiveState=(.+)/\1/p' <<< "$show_out" )
                v_res=$( sed -En 's/^Result=(.+)/\1/p' <<< "$show_out" )
                v_emc=$( sed -En 's/^ExecMainCode=(.+)/\1/p' <<< "$show_out" )
                v_ems=$( sed -En 's/^ExecMainStatus=(.+)/\1/p' <<< "$show_out" )
                v_est=$( sed -En 's/^ExecMainStartTimestamp=(.+)/\1/p' <<< "$show_out" )
                v_eet=$( sed -En 's/^ExecMainExitTimestamp=(.+)/\1/p' <<< "$show_out" )

                case $v_as in
                    ( active )
                        status_msgs+=( "  The borg-go service is currently active" )
                        status_msgs+=( "  started: $v_est" )
                    ;;
                    ( inactive )
                        status_msgs+=( "  The last run of borg-go.service was successful" )
                        status_msgs+=( "  started:  $v_est" "  finished: $v_eet" )
                    ;;
                    ( failed )
                        status_msgs+=( "  The borg-go service failed with reason '$v_res' and status code '$v_ems'" )
                        status_msgs+=( "  started:  $v_est" "  finished: $v_eet" )
                    ;;
                    ( * )
                        # activating, etc.
                        el_msg 6 "unexpected value for ActiveState: '$v_as'"
                        exit
                    ;;
                esac
            fi
        else
            el_msg $ec "systemctl return status unexpected: $ec"
            exit
        fi
    fi
    status_msgs+=( "" )

    if systemctl is-active --quiet borg-go.timer
    then
        # typical; get more info
        show_out=$( systemctl show borg-go.timer )
        # Triggers=borg-go.service
        # SubState=waiting
        # LastTriggerUSec=Thu
        # NextElapseUSecRealtime=Fri

        # NB, I have added 'Persistent=true' to the timers section, so
        # the last triggered time should be saved across reboots, and it
        # shouldn't be necessary to check for something like
        # ExecMainStartTimestampMonotonic > 0

        local v_trg v_ss v_lt v_nt
        v_trg=$( sed -En 's/^Triggers=(.+)/\1/p' <<< "$show_out" )
        v_ss=$( sed -En 's/^SubState=(.+)/\1/p' <<< "$show_out" )
        v_lt=$( sed -En 's/^LastTriggerUSec=(.+)/\1/p' <<< "$show_out" )
        v_nt=$( sed -En 's/^NextElapseUSecRealtime=(.+)/\1/p' <<< "$show_out" )

        status_msgs+=( "  borg-go.timer is currently active," "    and set to trigger $v_trg" )

        [[ $v_ss == waiting ]] \
            || status_msgs+=( "  borg-go.timer is not listed as waiting; SubState = '$v_ss'" )

        status_msgs+=( "  last trigger: $v_lt" )
        status_msgs+=( "  next trigger: $v_nt" )

    else
        ec=$?
        if (( ec == 4 ))
        then
            el_msg 4 "borg-go.timer not found by systemctl"
            exit

        elif (( ec == 3 ))
        then
            status_msgs+=( "  borg-go.timer is currently inactive" )

        else
            el_msg $ec "systemctl return status unexpected: $ec"
            exit
        fi
    fi
    status_msgs+=( "" )

    printf >&2 '%s\n' "${status_msgs[@]}"
}
