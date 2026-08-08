#!/usr/bin/env bash

set -e

DB_DIR="$(mktemp --directory)"

stack run -- --db "$DB_DIR" &
SERVER_PID=$!
sleep 0.5s
# kill all spawned processes
trap 'kill $SERVER_PID; rm -r $DB_DIR' EXIT


BASE=http://localhost:31337

die() {
    echo "$@"
    exit 1
}

jcurl() {
    if [ "$#" -eq 2 ]; then
        curl -s "$BASE/$1" --header 'Content-Type: application/json' --data "$2" --fail-with-body \
            || die "exiting with curl error"
    else
        curl -s "$BASE/$1" --header 'Content-Type: application/json' --data "$2" --header "X-Tabsend-Auth: $3" --fail-with-body \
            || die "exiting with curl error"
    fi
}

TOKEN1="$(jcurl "token" '{"username": "admin", "password": "qwe", "peerName": "peer1"}')"
TOKEN2="$(jcurl "token" '{"username": "admin", "password": "qwe", "peerName": "peer2"}')"


# Both parties send some tabs
jcurl "update" '{"tabs": [{"url": "url1", "identity": "id1", "title": "t1", "favicon": "f1", "inFlight": false}]}' "$TOKEN1"
jcurl "update" '{"tabs": [{"url": "url2", "identity": "id2", "title": "t2", "favicon": "f2", "inFlight": false}]}' "$TOKEN2"
# Party 1 grabs a tab
jcurl "grab-tab" '{"target": "peer2", "tabId": "id2"}' "$TOKEN1"
# Confirm it's remembered as grabbed
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer2","tabs":[{"favicon":"f2","identity":"id2","inFlight":true,"title":"t2","url":"url2"}]}]' ] \
    || die "Tab is not grabbed at all: $r"

# Restart the server
kill "$SERVER_PID"
stack run -- --db "$DB_DIR" &
SERVER_PID=$!
sleep 0.5s

# Confirm it's remembered as grabbed
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer2","tabs":[{"favicon":"f2","identity":"id2","inFlight":true,"title":"t2","url":"url2"}]}]' ] \
    || die "Tab is not grabbed after restart: $r"

echo -e "\nSUCCESS"
