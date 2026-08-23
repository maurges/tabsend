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

# Send no tabs, see that noone yet pushed anything
r="$(jcurl "update" '{"tabs": []}' "$TOKEN1")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update of peer 1: $r"
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update of peer 2: $r"

# Send some tabs, see them in peer info
jcurl "update" '{"tabs": [{"url": "url1", "identity": "id1", "title": "t1", "favicon": "f1", "inFlight": false}]}' "$TOKEN1"
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer2","tabs":[]}]' ] \
    || die "Unexpected tabs from peer2@1: $r"
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN2" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer1","tabs":[{"favicon":"f1","identity":"id1","inFlight":false,"title":"t1","url":"url1"}]}]' ] \
    || die "Unexpected tabs from peer1@1: $r"

jcurl "update" '{"tabs": [{"url": "url2", "identity": "id2", "title": "t2", "favicon": "f2", "inFlight": false}]}' "$TOKEN2"
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer2","tabs":[{"favicon":"f2","identity":"id2","inFlight":false,"title":"t2","url":"url2"}]}]' ] \
    || die "Unexpected tabs from peer2@2: $r"
r="$(curl -s "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN2" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer1","tabs":[{"favicon":"f1","identity":"id1","inFlight":false,"title":"t1","url":"url1"}]}]' ] \
    || die "Unexpected tabs from peer1@2: $r"

# Push a tab
jcurl "push-tab" '{"target": "peer2", "tab": {"url": "url3", "identity": "id3", "title": "t3", "favicon": "f3", "inFlight": false}}' "$TOKEN1"
# Observe it in notification
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[{"tabId":"id3","url":"url3"}]}' ] || die "Bad update after push: $r"

# Acknowledge the push
jcurl "acknowledge" '{"pushedTabs": ["id3"], "grabbedTabs": [], "tabs": [{"url": "url3", "identity": "id3", "title": "t3", "favicon": "f3", "inFlight": false}]}' "$TOKEN2"
# Observe its absence in notification
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update after ack: $r"

echo -e "\nSUCCESS"
