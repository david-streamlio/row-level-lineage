#!/usr/bin/env bash
# Pinned title for a recorded terminal window: sets the window title (as
# talk 3's window scripts do), clears the screen and scrollback, draws a
# title bar on the first row, and confines scrolling to the rows below it --
# so the title stays in the video however much output follows. The recorder
# crops Terminal's own title bar away, hence the in-window bar.
#
#   bash demo/record-windows/header.sh "Title"
title="$1"
rows=$(tput lines 2>/dev/null || echo 24)
cols=$(tput cols 2>/dev/null || echo 80)
printf '\033]0;%s\007' "$title"
printf '\033[r\033[2J\033[3J\033[H'                      # reset scroll region; clear incl. scrollback
printf '\033[1;38;5;231;48;5;55m %-*.*s\033[0m\n' "$(( cols - 1 ))" "$(( cols - 1 ))" "$title"   # white on purple
printf '\033[3;%dr\033[3;1H' "$rows"                     # scroll rows 3..bottom; cursor to row 3
