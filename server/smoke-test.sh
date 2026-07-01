#!/usr/bin/env bash

set -e
# kill all spawned processes
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

stack run &
sleep 0.5s

BASE=http://localhost:31337

jcurl() {
    if [ "$#" -eq 2 ]; then
        curl "$BASE/$1" --header 'Content-Type: application/json' --data "$2" --fail-with-body
    else
        curl "$BASE/$1" --header 'Content-Type: application/json' --data "$2" --header "X-Tabsend-Auth: $3" --fail-with-body
    fi
}

die() {
    echo "$@"
    exit 1
}

TOKEN1="$(jcurl "token" '{"username": "u", "password": "p", "peerName": "peer1"}')"
TOKEN2="$(jcurl "token" '{"username": "u", "password": "p", "peerName": "peer2"}')"

# Send no tabs, see that noone yet pushed anything
r="$(jcurl "update" '{"tabs": []}' "$TOKEN1")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update of peer 1: $r"
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update of peer 2: $r"

# Send some tabs, see them in peer info
jcurl "update" '{"tabs": [{"url": "url1", "identity": "id1", "title": "t1", "favicon": "f1"}]}' $TOKEN1
r="$(curl "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer1","tabs":[{"favicon":"f1","identity":"id1","title":"t1","url":"url1"}]},{"name":"peer2","tabs":[]}]' ] || die "Unexpected tabs from peer1: $r"

jcurl "update" '{"tabs": [{"url": "url2", "identity": "id2", "title": "t2", "favicon": "f2"}]}' $TOKEN2
r="$(curl "$BASE/get-peers" --header "X-Tabsend-Auth: $TOKEN1" --fail-with-body | jq -c '.peers | sort')"
[ "$r" == '[{"name":"peer1","tabs":[{"favicon":"f1","identity":"id1","title":"t1","url":"url1"}]},{"name":"peer2","tabs":[{"favicon":"f2","identity":"id2","title":"t2","url":"url2"}]}]' ] || die "Unexpected tabs from peer2: $r"

# Push a tab
jcurl "push-tab" '{"target": "'"$TOKEN2"'", "tab": {"url": "url3", "identity": "id3", "title": "t3", "favicon": "f3"}}' $TOKEN1
# Observe it in notification
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[{"tabId":"id3","url":"url3"}]}' ] || die "Bad update after push: $r"

# Acknowledge the push
jcurl "acknowledge" '{"pushedTabs": ["id3"], "grabbedTabs": []}' "$TOKEN2"
# Observe its absence in notification
r="$(jcurl "update" '{"tabs": []}' "$TOKEN2")"
[ "$r" == '{"grabbedTabs":[],"pushedTabs":[]}' ] || die "Bad update after ack: $r"
