/// <reference path="../types/webext.d.ts" />

// Need to allow requests to the server domain.
// We can request at runtime the specific domain with something like this:
// https://stackoverflow.com/questions/71913706/is-it-possible-for-a-webextension-addon-to-request-permission-for-a-specific-web


/****************************/
/****** Error handling ******/
/****************************/


/**
 * @param {string} s
 * @returns {never}
 */
function panic(s) {
    throw new Error("Panic: " + s);
}

/**
 * @template A
 * @param {A | null | undefined} x
 * @param {string} s - error message
 * @returns {A}
 */
function expect(x, s) {
    if (x === null || x === undefined) {
        panic("unwrap: " + s);
    }
    return x;
}


/******************************/
/****** Type definitions ******/
/******************************/


/** @typedef {{username: string, password: string}} TokenReq */
/** @typedef {{url: string, identity: string, title: string}} TabInfo */
/** @typedef {{title: string, tabs: TabInfo[]}} WindowInfo */
/** @typedef {{name: string, windows: WindowInfo[]}} PeerInfo */
/** @typedef {{peers: PeerInfo[]}} PeersResp */
/** @typedef {{target: string, tab: TabInfo}} PushTabReq */
/** @typedef {{target: string, tabIdentity: string}} GrabTabReq */


/*********************************/
/****** Request definitions ******/
/*********************************/

/**
 * @param {string} baseUrl
 * @param {TokenReq} req
 * @returns {Promise<string>}
 */
async function getTokenR(baseUrl, req) {
    const url = baseUrl + "/token";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
        },
    });
    return r.text();
}

/**
 * @param {string} baseUrl
 * @param {string} authToken
 * @returns {Promise<PeersResp>}
 */
async function getPeersR(baseUrl, authToken) {
    const url = baseUrl + "/get-peers";
    const r = await fetch(url, {
        method: "GET",
        headers: {
            "X-Tabsend-Auth": authToken,
        },
    });
    // TODO: parse json
    return r.json();
}

/**
 * @param {string} baseUrl
 * @param {string} authToken
 * @param {PushTabReq} req
 * @returns {Promise<string>}
 */
async function pushTabR(baseUrl, authToken, req) {
    const url = baseUrl + "/push-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": authToken,
        },
    });
    return r.text();
}

/**
 * @param {string} baseUrl
 * @param {string} authToken
 * @param {GrabTabReq} req
 * @returns {Promise<string>}
 */
async function grabTabR(baseUrl, authToken, req) {
    const url = baseUrl + "/grab-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": authToken,
        },
    });
    return r.text();
}


/****************************/
/****** Main extension ******/
/****************************/


/**
 * @param {string} id
 * @returns {HTMLElement}
 */
function byId(id) {
    return expect(document.getElementById(id), "malformed page");
}

/**
 * @param {string} baseUrl
 * @param {string} token
 * @param {TabInfo} tab
 * @param {string} targetPeer
 */
async function grabTab(baseUrl, token, tab, targetPeer) {
    await browser.tabs.create({
        active: true,
        url: tab.url,
    });
    grabTabR(baseUrl, token, {target: targetPeer, tabIdentity: tab.identity});
}

/**
 * @param {string} baseUrl
 * @param {string} token
 * @param {TabInfo} tab - parsed tab to remove undefineds
 * @param {string} targetPeer
 */
async function pushTab(baseUrl, token, tab, targetPeer) {
    await pushTabR(baseUrl, token, { target: targetPeer, tab });
    const tabId = parseInt(tab.identity) || [];
    browser.tabs.remove(tabId);
}

/**
 * @param {string} baseUrl
 * @param {string} token
 * @param {browser.tabs.Tab} tab
 * @returns {HTMLElement}
 */
function makeTabEntry(baseUrl, token, tab) {
    const tabTitle = expect(tab.title, "not enough tab permissions to get tab title");
    const tabUrl = expect(tab.url, "not enough tab permissions to get tab url");
    const tabId = expect(tab.id, "not enough tab permissions to get tab id").toString();

    const span = document.createElement("span");
    span.innerText = tabTitle;
    const button = document.createElement("button");
    button.innerText = "send"
    span.appendChild(button);
    button.onclick = () => {
        const tabToSend = {
            url: tabUrl,
            identity: tabId,
            title: tabTitle,
        };
        pushTab(baseUrl, token, tabToSend, "todo");
    };
    return span;
}

async function run() {
    const thisDeviceUl = byId("this-device");
    const allTabsDiv = byId("all-tabs");

    const baseUrl = "http://localhost:31337";
    const token = await getTokenR(baseUrl, { username: "username", password: "password" });

    // draw windows from this device

    const windows = await browser.windows.getAll({populate: true});
    for (const w of windows) {
        const windowElem = document.createElement("li");
        windowElem.innerText = expect(w.title, "not enough tab permissions to get tab title");
        const ul = document.createElement("ul");
        windowElem.appendChild(ul)

        const winTabs = expect(w.tabs, "not enough tab permissions to get window tabs");
        for (const tab of winTabs) {
            const tabElem = makeTabEntry(baseUrl, token, tab);
            const li = document.createElement("li");
            li.appendChild(tabElem);
            ul.appendChild(li);
        }

        thisDeviceUl.appendChild(windowElem);
    }

    // draw windows from other peers too

    const peers = await getPeersR(baseUrl, token);
    for (const peer of peers.peers) {
        const peerDiv = document.createElement("div");
        peerDiv.innerText = peer.name;
        const peerUl = document.createElement("ul");
        peerDiv.appendChild(peerUl);

        for (const w of peer.windows) {
            const windowElem = document.createElement("li");
            peerUl.appendChild(windowElem);
            windowElem.innerText = w.title;
            const ul = document.createElement("ul");
            windowElem.appendChild(ul)
            for (const tab of w.tabs) {
                const li = document.createElement("li");

                const tabElem = document.createElement("span");
                tabElem.innerText = tab.title;

                const grabButton = document.createElement("button");
                grabButton.innerText = "grab";
                grabButton.onclick = () => {
                    grabTab(baseUrl, token, tab, peer.name);
                };

                li.appendChild(tabElem);
                li.appendChild(grabButton);
                ul.appendChild(li);
            }
        }
        allTabsDiv.appendChild(peerDiv);
    }
}

run();
