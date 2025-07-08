#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

if [[ -f /app/.no_docker ]]; then
  INGESTOR_CHECK="$(systemctl is-active acw-ingestor)"
  DETECTOR_CHECK="$(systemctl is-active acw-change-detector)"
fi

# Print prompt title
echo "====== Autocaliweb -- Status of Monitoring Services ======"
echo ""

if [ "$INGESTOR_CHECK" == "active" ] || s6-rc -a list >/dev/null 2>&1 | grep -q 'acw-ingest-service'; then
  echo -e "- acw-ingest-service ${GREEN}is running${NC}"
  is=true
else
  echo -e "- acw-ingest-service ${RED}is not running${NC}"
  is=false
fi

if [ "$DETECTOR_CHECK" == "active" ] || s6-rc -a list >/dev/null 2>&1 | grep -q 'metadata-change-detector'; then
  echo -e "- metadata-change-detector ${GREEN}is running${NC}"
  mc=true
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
  if [ "$is" = true ] && [ "$mc" = false ]; then
    exit 1
  elif [ "$is" = false ] && [ "$mc" = true ]; then
    exit 2
  else
    exit 3
  fi
fi
