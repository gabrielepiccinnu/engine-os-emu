#!/bin/bash
# Presses the buttons of the Mixstream Pro's control surface, which under
# emulation is the virtual MIDI card snd-combined.c provides.
#
#     bash surface.sh load 1            load the selected track into deck 1
#     bash surface.sh play 2            play/pause deck 2
#     bash surface.sh cue 1             cue deck 1
#     bash surface.sh sync 1            sync deck 1
#     bash surface.sh browse 3          turn the browse encoder three steps down
#     bash surface.sh browse -1         one step up
#     bash surface.sh push              press the browse encoder
#     bash surface.sh back              the BACK button
#     bash surface.sh view              the VIEW button
#     bash surface.sh note 15 6         Note On/Off on channel 15, note 6 (a press)
#     bash surface.sh cc 15 5 1         Control Change on channel 15, cc 5, value 1
#     bash surface.sh raw "9f 01 7f"    any bytes, as amidi -S takes them
#
# The numbers come from the product's own assignment file in the rootfs,
# /usr/Engine/AssignmentFiles/PresetAssignmentFiles/NH08/NH08_Controller_Assignments.qml,
# and from the modules it instantiates:
#
#   global channel 15:  LOAD deck 1/2 = notes 1/2, BACK 3, browse push 6 and
#                       turn CC 5, MENU 7, VIEW 16
#   deck channels 2/3:  SYNC 8, CUE 9, PLAY 10, shift 28, pads from 15
#
# Channels are as the file writes them, zero based: channel 15 is status
# 0x9F. LOAD sits on the global channel although it is drawn per deck: the
# Load module takes globalConfig.midiChannel and tells the decks apart by
# note. Engine reads the bytes only once it has identified the surface,
# which takes it about half a minute after Engine starts.
set -e
BASE="$(cd "$(dirname "$0")/.." && pwd)"
VM="$BASE/_vm"

cp -f "$VM/id_vm" /tmp/id_vm; chmod 600 /tmp/id_vm
SSHOPT="-p 2222 -i /tmp/id_vm -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o LogLevel=ERROR"
PORT="hw:Surface,1"

GLOBAL=15
deck_channel() { case "$1" in 1) echo 2;; 2) echo 3;; *) echo "deck must be 1 or 2" >&2; exit 1;; esac; }

send() { ssh $SSHOPT root@127.0.0.1 "amidi -p $PORT -S '$1'"; }
hex() { printf '%02x' "$1"; }
# a press: Note On with velocity 127, then Note Off
press() { send "$(hex $((0x90 + $1))) $(hex $2) 7f"; sleep 0.15; send "$(hex $((0x80 + $1))) $(hex $2) 00"; }
cc() { send "$(hex $((0xb0 + $1))) $(hex $2) $(hex $3)"; }

case "${1:-}" in
    load)   press $GLOBAL "$2"; echo "LOAD deck $2" ;;
    play)   press "$(deck_channel "$2")" 10; echo "PLAY deck $2" ;;
    cue)    press "$(deck_channel "$2")" 9;  echo "CUE deck $2" ;;
    sync)   press "$(deck_channel "$2")" 8;  echo "SYNC deck $2" ;;
    push)   press $GLOBAL 6;  echo "browse encoder pressed" ;;
    back)   press $GLOBAL 3;  echo "BACK" ;;
    menu)   press $GLOBAL 7;  echo "MENU" ;;
    view)   press $GLOBAL 16; echo "VIEW" ;;
    browse)
        n="${2:-1}"
        # a relative encoder: 1 is one step down, 127 (-1) one step up
        if [ "$n" -lt 0 ]; then v=127; n=$((-n)); else v=1; fi
        for i in $(seq 1 "$n"); do cc $GLOBAL 5 $v; sleep 0.1; done
        echo "browse encoder: $2" ;;
    note)   press "$2" "$3"; echo "note $3 on channel $2" ;;
    cc)     cc "$2" "$3" "$4"; echo "cc $3 = $4 on channel $2" ;;
    raw)    send "$2"; echo "sent: $2" ;;
    *)      sed -n '2,20p' "$0"; exit 1 ;;
esac
