#    SPDX-License-Identifier: Apache License 2.0
#
#    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
#
#    Author: Jaco Hofmann (jaco.hofmann@wdc.com)

tmux \
  new-session "echo 'Starting simulation';./utils/run_socket.sh 4" \; \
  split-window -h "echo 'Starting TUI';./host_software/omnixtend-tui/target/release/omnixtend-tui -i veth1" \; \
  split-window -h "echo 'Starting TUI';./host_software/omnixtend-tui/target/release/omnixtend-tui -i veth2" \; \
  split-window -h "echo 'Starting TUI';./host_software/omnixtend-tui/target/release/omnixtend-tui -i veth3" \; \
  select-layout tiled