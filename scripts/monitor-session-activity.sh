#!/usr/bin/env bash

set -euo pipefail

get_tmux_option() {
    local option_value
    option_value=$(tmux show-option -gqv "$1")
    echo "${option_value:-$2}"
}

######
# Configurable options
#
# Usage example:
# set -g @aw-watcher-tmux-host 'my.aw-server.test'

POLL_INTERVAL=$(get_tmux_option "@aw-watcher-tmux-poll-interval" 10) # seconds
HOST=$(get_tmux_option "@aw-watcher-tmux-host" "localhost")
PORT=$(get_tmux_option "@aw-watcher-tmux-port" "5600")
PULSETIME=$(get_tmux_option "@aw-watcher-tmux-pulsetime" "120.0")

BUCKET_ID="aw-watcher-tmux_$(hostname)"
API_URL="http://$HOST:$PORT/api"

######
# Related documentation:
#  * https://github.com/tmux/tmux/wiki/Formats
#  * https://github.com/tmux/tmux/wiki/Advanced-Use#user-content-getting-information
#

### FUNCTIONS

DEBUG=0

init_bucket() {
    local http_code
    http_code=$(curl -X GET "${API_URL}/0/buckets/$BUCKET_ID" -H "accept: application/json" -s -o /dev/null -w "%{http_code}")

    if [[ "$http_code" == "404" ]]; then
        local json
        json="{\"client\":\"$BUCKET_ID\",\"type\":\"tmux.sessions\",\"hostname\":\"$(hostname)\"}"
        http_code=$(curl -X POST "${API_URL}/0/buckets/$BUCKET_ID" -H "accept: application/json" -H "Content-Type: application/json" -d "$json" -s -o /dev/null -w "%{http_code}")

        if [[ "$http_code" != "200" ]]; then
            echo "ERROR: Failed to create bucket (HTTP $http_code)" >&2
            exit 1
        fi
    fi
}

log_to_bucket() {
    local sess="$1"

    if ! tmux has-session -t "$sess" 2>/dev/null; then
        echo "WARNING: Session '$sess' no longer exists" >&2
        return 1
    fi

    local data
    data=$(tmux display -t "$sess" -p "{\"title\":\"#{session_name}\",\"session_name\":\"#{session_name}\",\"window_name\":\"#{window_name}\",\"pane_title\":\"#{pane_title}\",\"pane_current_command\":\"#{pane_current_command}\",\"pane_current_path\":\"#{pane_current_path}\"}")

    local payload
    payload="{\"timestamp\":\"$(date -Iseconds)\",\"duration\":0,\"data\":$data}"

    [[ "$DEBUG" -eq 1 ]] && echo "Payload: $payload" >&2

    local http_code
    http_code=$(curl -X POST "${API_URL}/0/buckets/$BUCKET_ID/heartbeat?pulsetime=$PULSETIME" -H "accept: application/json" -H "Content-Type: application/json" -d "$payload" -s -o /dev/null -w "%{http_code}")

    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: Failed to log session '$sess' (HTTP $http_code)" >&2
        return 1
    fi
}

### MAIN POLL LOOP

init_bucket

while true; do
    if ! tmux list-sessions &>/dev/null; then
        echo "INFO: No tmux server running, exiting" >&2
        exit 0
    fi

    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || echo "")

    if [[ -n "$sessions" ]]; then
        while IFS= read -r sess; do
            [[ -z "$sess" ]] && continue

            if act_time=$(tmux display -t "$sess" -p '#{session_activity}' 2>/dev/null); then
                last_activity_file="/tmp/aw-tmux-${sess//[^a-zA-Z0-9]/_}"
                last_act=0

                if [[ -f "$last_activity_file" ]]; then
                    last_act=$(cat "$last_activity_file" 2>/dev/null || echo "0")
                fi

                if [[ "$act_time" -gt "$last_act" ]]; then
                    log_to_bucket "$sess"
                fi

                echo "$act_time" > "$last_activity_file"
            fi
        done <<< "$sessions"
    fi

    sleep "$POLL_INTERVAL"
done
