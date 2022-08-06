#!/usr/bin/env bash
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
set -euo pipefail

AUDIO_FIELD="audio"
SCREENSHOT_FIELD="image"
SENTENCE_FIELD="Sentence"
# leave OUTPUT_MONITOR blank to autoselect a monitor.
OUTPUT_MONITOR=""
AUDIO_BITRATE="64k"
AUDIO_FORMAT="opus"
AUDIO_VOLUME="1"
IMAGE_FORMAT="webp"
# -2 to calculate dimension while preserving aspect ratio.
IMAGE_WIDTH="-2"
IMAGE_HEIGHT="300"

CONFIG_FILE_PATH="$HOME/.config/ames/config"
POST_CONFIG_FILE_PATH="$HOME/.config/ames/post_config.sh"

if [[ -f "$CONFIG_FILE_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE_PATH"
fi

usage() {
    # display help
    echo "-h: display this help message"
    echo "-r: record audio toggle"
    echo "-s: interactive screenshot"
    echo "-a: screenshot same region again (defaults to -s if no region)"
    echo "-w: screenshot currently active window (xdotool)"
}

notify_screenshot_add() {
    if [[ "$LANG" == en* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "Screenshot added"
    fi
    if [[ "$LANG" == ja* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "スクリーンショット付けました"
    fi
}

maxn() {
    # compute the max element of a list
    tr -d ' ' | tr ',' '\n' | awk '
    BEGIN {
        max = 0
    }
    {
        if ($0 > max) {
            max = $0
        }
    }
    END {
        print max
    }
    '
}

get_last_id() {
    # get the id of the last card added to anki
    # result is stored in the global variable newest_card_id
    local new_card_request='{
        "action": "findNotes",
        "version": 6,
        "params": {
        "query": "added:1"
        }
    }'
    local new_card_response list

    new_card_response=$(ankiconnect_request "$new_card_request")
    list=$(echo "$new_card_response" | cut -d "[" -f2 | cut -d "]" -f1)
    newest_card_id=$(echo "$list" | maxn)
}

store_file() {
    # store a media file
    local -r dir=${1:?}
    local -r name=$(basename -- "$dir")
    local request='{
        "action": "storeMediaFile",
        "version": 6,
        "params": {
            "filename": "<name>",
            "path": "<dir>"
        }
    }'
    request=${request//<name>/$name}
    request=${request/<dir>/$dir}
    ankiconnect_request "$request" >>/dev/null
}

gui_browse() {
    # open the gui card browser and point the modified card
    local -r query=${1:-nid:1}
    local request='{
        "action": "guiBrowse",
        "version": 6,
        "params": {
            "query": "<QUERY>"
        }
    }'
    request=${request/<QUERY>/$query}
    ankiconnect_request "$request"
}

ankiconnect_request() {
    curl --silent localhost:8765 -X POST -d "${1:?}"
}

safe_request() {
    # only send requests after opening the gui browser
    gui_browse "nid:1"
    ankiconnect_request "${1:?}"
    gui_browse "nid:${newest_card_id:?Newest card is not known.}"
}

update_sentence() {
    # update card with sentence ($1)
    get_last_id
    local update_request='{
        "action": "updateNoteFields",
        "version": 6,
        "params": {
            "note": {
                "id": <id>,
                "fields": { "<SENTENCE_FIELD>": "<sentence>" }
            }
        }
    }'

    update_request=${update_request/<id>/$newest_card_id}
    update_request=${update_request/<SENTENCE_FIELD>/$SENTENCE_FIELD}
    sentence_esc=${1//\\/\\\\}
    sentence_esc=${sentence_esc//\"/\\\"}
    update_request=${update_request/<sentence>/$sentence_esc}
    safe_request "$update_request"
}

update_img() {
    # update card with image, given by the path in $1
    get_last_id
    local update_request='{
        "action": "updateNoteFields",
        "version": 6,
        "params": {
            "note": {
                "id": <id>,
                "fields": { "<SCREENSHOT_FIELD>": "<img src=\"<path>\">" }
            }
        }
    }'
    update_request=${update_request/<id>/$newest_card_id}
    update_request=${update_request/<SCREENSHOT_FIELD>/$SCREENSHOT_FIELD}
    update_request=${update_request/<path>/$1}

    safe_request "$update_request"
}

update_sound() {
    # update card with sound, given by the path to an audio file in $1
    get_last_id
    local update_request='{
        "action": "updateNoteFields",
        "version": 6,
        "params": {
            "note": {
                "id": <id>,
                "fields": {
                    "<AUDIO_FIELD>":"[sound:<path>]"
                 }
            }
        }
    }'
    update_request=${update_request/<id>/$newest_card_id}
    update_request=${update_request/<AUDIO_FIELD>/$AUDIO_FIELD}
    update_request=${update_request/<path>/$1}

    safe_request "$update_request"
}

encode_img() {
    # use ffmpeg to encode an image to some desired format
    local -r source_path="$1"
    local -r dest_path="$2"
    ffmpeg -nostdin \
        -hide_banner \
        -loglevel error \
        -i "$source_path" \
        -vf scale="$IMAGE_WIDTH:$IMAGE_HEIGHT" \
        "$dest_path"
}

screenshot() {
    # take a screenshot by prompting the user for a selection and then
    # add this image to the last anki card
    local -r geom=$(slop)
    local -r path=$(mktemp /tmp/maim-screenshot.XXXXXX.png)
    local -r base_path=$(basename -- "$path" | cut -d "." -f-2)
    local -r converted_path="/tmp/$base_path.$IMAGE_FORMAT"

    maim --hidecursor "$path" -g "$geom"
    encode_img "$path" "$converted_path"

    rm "$path"
    echo "$geom" >/tmp/previous-maim-screenshot
    store_file "$converted_path"
    update_img "$(basename -- "$converted_path")"
    notify_screenshot_add
}

again() {
    # if screenshot() has been called, then repeat take another screenshot
    # with the same dimensions as last time and add to the last anki card.
    # otherwise, cal screenshot()
    local -r path=$(mktemp /tmp/maim-screenshot.XXXXXX.png)
    local -r base_path=$(basename -- "$path" | cut -d "." -f-2)
    local -r converted_path="/tmp/$base_path.$IMAGE_FORMAT"

    if [[ -f /tmp/previous-maim-screenshot ]]; then
        maim --hidecursor "$path" -g "$(cat /tmp/previous-maim-screenshot)"
        encode_img "$path" "$converted_path"
        rm "$path"
        store_file "$converted_path"
        get_last_id
        update_img "$(basename -- "$converted_path")"
        notify_screenshot_add
    else
        screenshot
    fi
}

screenshot_window() {
    # take a screenshot of the active window and add to the last anki card.
    local -r path=$(mktemp /tmp/maim-screenshot.XXXXXX.png)
    local -r base_path=$(basename -- "$path" | cut -d "." -f-2)
    local -r converted_path="/tmp/$base_path.$IMAGE_FORMAT"
    maim --hidecursor "$path" -i "$(xdotool getactivewindow)"
    encode_img "$path" "$converted_path"
    rm "$path"
    store_file "$converted_path"
    update_img "$(basename -- "$converted_path")"
    notify_screenshot_add
}

current_time() {
    # current time as an integer number of milliseconds since the epoch
    echo "$(date '+%s')$(date '+%N' | awk '{ print substr($1, 0, 3) }')"
}

record_function() {
    # function to record desktop audio. $1 is the name of the output
    # monitor, $2 is the output file name.

    # the last function called here MUST be the call to ffmpeg or some
    # other program that does recording. When -r is called again, the
    # pid of the last function call is killed.
    local -r output="$1"
    local -r audio_file="$2"
    ffmpeg -nostdin \
        -y \
        -loglevel error \
        -f pulse \
        -i "$output" \
        -ac 2 \
        -af "volume=${AUDIO_VOLUME},silenceremove=1:0:-50dB" \
        -ab "$AUDIO_BITRATE" \
        "$audio_file" 1>/dev/null &
}

record_start() {
    # begin recording audio.
    local -r audio_file=$(mktemp \
                              "/tmp/ffmpeg-recording.XXXXXX.$AUDIO_FORMAT")
    echo "$audio_file" >"$recording_toggle"

    if [ "$OUTPUT_MONITOR" == "" ]; then
        local -r output=$(pactl info \
                              | grep 'Default Sink' \
                              | awk '{print $NF ".monitor"}')
    else
        local -r output="$OUTPUT_MONITOR"
    fi

    record_function "$output" "$audio_file"
    echo "$!" >> "$recording_toggle"

    current_time >> "$recording_toggle"

    if [[ "$LANG" == en* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "Recording started..."
    fi
    if [[ "$LANG" == ja* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "録音しています..."
    fi
}

record_end() {
    # end recording
    local -r audio_file="$(sed -n "1p" "$recording_toggle")"
    local -r pid="$(sed -n "2p" "$recording_toggle")"
    local -r start_time="$(sed -n "3p" "$recording_toggle")"
    local -r duration="$(($(current_time) - start_time))"

    rm "$recording_toggle"
    kill -15 "$pid"

    while [ "$(du "$audio_file" | awk '{ print $1 }')" -eq 0 ]; do
        true
    done

    local -r audio_backup="/tmp/ffmpeg-recording-audio-backup.$AUDIO_FORMAT"
    cp "$audio_file" "$audio_backup"
    ffmpeg -nostdin \
           -y \
           -loglevel error \
           -i "$audio_backup" \
           -c copy \
           -to "${duration}ms" \
           "$audio_file" 1>/dev/null

    store_file "${audio_file}"
    update_sound "$(basename -- "$audio_file")"

    if [[ "$LANG" == en* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "Recording added"
    fi
    if [[ "$LANG" == ja* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "録音付けました"
    fi

}

record() {
    # this section is a heavily modified version of the linux audio
    # script written by salamander on qm's animecards.
    recording_toggle="/tmp/ffmpeg-recording-audio"

    if [[ ! -f /tmp/ffmpeg-recording-audio ]]; then
        record_start
    else
        record_end
    fi
}

copied_text() {
    # get the contents of the clipboard
    if command -v xclip &> /dev/null
    then
        xclip -o
    elif command -v xsel &> /dev/null
    then
        xsel -b
    else
        echo "Couldn't find xclip or xsel." >&2
        exit
    fi
}

clipboard() {
    # get the current clipboard, and add this text to the last Anki card.
    local -r sentence=$(copied_text)
    update_sentence "${sentence}"

    if [[ "$LANG" == en* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "Sentence added"
    fi
    if [[ "$LANG" == ja* ]]; then
        notify-send --hint=int:transient:1 -t 500 -u normal \
                    "例文付けました"
    fi
}

if [[ -f "$POST_CONFIG_FILE_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$POST_CONFIG_FILE_PATH"
fi

if [[ -z ${1-} ]]; then
    usage
    exit 1
fi

while getopts 'hrsawc' flag; do
    case "${flag}" in
        h) usage ;;
        r) record ;;
        s) screenshot ;;
        a) again ;;
        w) screenshot_window ;;
        c) clipboard ;;
        *) ;;
    esac
done
