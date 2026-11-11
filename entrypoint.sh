#!/bin/bash
cd /home/container
export INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')

# Turn Pterodactyl's {{VARIABLE}} syntax into real values, then run the startup command
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)")
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n" "$PARSED"
exec env ${PARSED}
