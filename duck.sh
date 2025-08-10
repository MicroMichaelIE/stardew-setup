#!/bin/bash
: "${DUCKDNS_DOMAIN:?DUCKDNS_DOMAIN is not set}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN is not set}"

mkdir -p ~/duckdns

echo url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" | curl -k -o ~/duckdns/duck.log -K -
