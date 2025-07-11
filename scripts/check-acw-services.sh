#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Print promt title
echo "====== Autocaliweb -- Status of Monitoring Services ======"
echo ""


if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet acw-ingest-service; then
    echo -e "- acw-ingest-service ${GREEN}is running${NC} (systemd)"
    is=true
elif s6-rc -a list | grep -q 'acw-ingest-service'; then
    echo -e "- acw-ingest-service ${GREEN}is running${NC}"
    is=true
else
    echo -e "- acw-ingest-service ${RED}is not running${NC}"
    is=false
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet metadata-change-detector; then
    echo -e "- metadata-change-detector ${GREEN}is running${NC} (systemd)"
    mc=true
elif s6-rc -a list | grep -q 'metadata-change-detector'; then
    echo -e "- metadata-change-detector ${GREEN}is running${NC}"
    is=true
else
    echo -e "- metadata-change-detector ${RED}is not running${NC}"
    mc=false
fi

echo ""

if $is && $mc; then
    echo -e "Autocaliweb was ${GREEN}successfully installed ${NC}and ${GREEN}is running properly!${NC}"
    exit 0
else
    echo -e "Autocaliweb was ${RED}not installed successfully${NC}, please check the logs for more information."
    if [ "$is" = true ] && [ "$mc" = false ] ; then
        exit 1
    elif [ "$is" = false ] && [ "$mc" = true ] ; then
        exit 2
    else
        exit 3
    fi
fi