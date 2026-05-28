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


async function sleep(time) {
    return new Promise(accept => setTimeout(accept, time));
}


/******************************/
/****** Type definitions ******/
/******************************/


/** @typedef {{username: string, password: string}} TokenReq */
/** @typedef {{url: string, identity: string, title: string, favicon: string | null}} TabInfo */
/** @typedef {{name: string, windows: TabInfo[]}} PeerInfo */
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


/***********************/
/****** UI models ******/
/***********************/


/** @typedef {{ title: string, favicon: string|null, url: string }} TabData */


/**
 * @param {DragEvent} e
 * @param {TabData} tab
 * @param {string} deviceName
 */
function onDragStart(e, tab, deviceName) {
    dragModel.sourcePane = deviceName;
    dragModel.tabData = tab;
    if (e.dataTransfer === null) {
        panic("Data transfer is null");
    }
    e.dataTransfer.dropEffect = "move";
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", tab.title)
}


/** @type {{ tabs: TabData[] }} */
let localTabModel = { tabs: [] };
/** @type {{ devices: { name: string, tabs: TabData[] }[] }} */
let remoteDeviceModel = { devices: [] };
/** @type {{ hoverPanes: {[name: string]: boolean}, sourcePane: string | null, tabData: TabData | null }} */
let dragModel = { hoverPanes: {}, sourcePane: null, tabData: null };

async function populateTabs() {
    const tabs = await browser.tabs.query({});
    let tabModel = [];
    for (const tab of tabs) {
        tabModel.push({
            title: expect(tab.title, "no permissions for title"),
            url: expect(tab.url, "no permissions for url"),
            favicon: tab.favIconUrl || null,
        });
    }
    localTabModel.tabs = tabModel;
}

document.addEventListener("alpine:init", () => {
    // Define Alpine types that we use for typescript checking
    /** @type {{ reactive: <T>(v: T) => T, data: <T>(name: string, fn: () => T) => void }} */
    const Alpine = /** @type {any} */ (globalThis).Alpine;

    localTabModel = Alpine.reactive(localTabModel);
    Alpine.data("localTabModel", () => localTabModel);
    remoteDeviceModel = Alpine.reactive(remoteDeviceModel);
    Alpine.data("remoteDeviceModel", () => remoteDeviceModel);
    dragModel = Alpine.reactive(dragModel);

    Alpine.data("globalFunctions", () => ({
        dragModel,
        onDragStart,
        onDragEnd: () => {
            dragModel.sourcePane = null;
            dragModel.tabData = null;
        },
        shouldShowHover: (/** @type {string} */name) => {
            return dragModel.sourcePane !== name && dragModel.hoverPanes[name];
        },
        onDragOver: (/** @type {string} */name, /** @type {DragEvent} */ev) => {
            ev.preventDefault();
            dragModel.hoverPanes[name] = true;
        },
        onDragLeave: (/** @type {string} */name, /** @type {DragEvent} */ev, /** @type {HTMLElement} */el) => {
            // Dismiss leave if we're entering the child
            if (el.contains(/** @type {Node} */ (ev.relatedTarget))) {
                return;
            }
            dragModel.hoverPanes[name] = false;
        },
        onDrop: (/** @type {string} */name, /** @type {DragEvent} */ev) => {
            ev.preventDefault();

            // TODO: This fires on drops of anything, not just the tab, and some things we could accept

            if (dragModel.sourcePane !== name) {
                console.log("Accepting drop to", name, dragModel.tabData);
            }
            // Since dragLeave doesn't fire in this case
            dragModel.hoverPanes[name] = false;
        },
    }));
});

localTabModel.tabs = [
    { title: "Take that you worm", favicon: "https://www.google.com/favicon.ico", url: "X" },
    { title: "This will overflow with a really fucking cool effect if I do say so", favicon: null, url: "X" },
    { title: "Whoa overlapping", favicon: null, url: "X" },
];
remoteDeviceModel.devices = [
    { name: "lover", tabs: [
        { title: "Take that you worm", favicon: null, url: "X" },
        { title: "This will overflow with a really fucking cool effect if I do say so", favicon: "https://www.google.com/favicon.ico", url: "X" },
    ] },
    { name: "friend that you're not sure if anything will happen", tabs: [
        { title: "Ward", favicon: "https://www.google.com/favicon.ico", url: "X" },
        { title: "Infinite regression epilogues", favicon: null, url: "X" },
    ] },
];

// Populate tabs model initially, update it every time tabs change
populateTabs();
browser.tabs.onCreated.addListener(() => populateTabs());
browser.tabs.onUpdated.addListener(() => populateTabs(), {properties: ["title"]})
// Sleep is needed because at the moment of this even the tab is not yet removed
browser.tabs.onRemoved.addListener(async () => { await sleep(100); populateTabs() });
