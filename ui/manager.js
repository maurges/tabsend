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


async function sleep(/** @type {number} */time) {
    return new Promise(accept => setTimeout(accept, time));
}


/******************************/
/****** Type definitions ******/
/******************************/


/** @typedef {{
 *      username: string,
 *      password: string,
 *  }} TokenReq
 */

/** @typedef {{
 *      url: string,
 *      identity: string,
 *      title: string,
 *      favicon: string | null,
 *      state?: "grayed",
 *  }} TabInfo
 */

/** @typedef {{
 *      name: string,
 *      tabs: TabInfo[],
 *  }} PeerInfo
 */

/** @typedef {{
 *      peers: PeerInfo[],
 *  }} PeersResp
 */

/** @typedef {{
 *      target: string,
 *      tab: TabInfo,
 *  }} PushTabReq
 */

/** @typedef {{
 *      target: string,
 *      tabId: string,
 *  }} GrabTabReq
 */


/*********************************/
/****** Request definitions ******/
/*********************************/


// Token and url are stored in the settings, without them set nothing works
/** @type {string | null} */
let baseUrl = null; // TODO idk
/** @type {string | null} */
let accessToken = null;
browser.storage.local.get(["remote-url", "access-token"]).then(async r => {
    baseUrl = r["remote-url"];
    accessToken = r["access-token"];
    await populateRemoteTabs();
});
browser.storage.onChanged.addListener(async (changes, areaName) => {
    if (areaName !== "local")  return;

    let didChange = false;
    if (changes["remote-url"]) {
        baseUrl = changes["remote-url"].newValue;
        didChange = true;
    }
    if (changes["access-token"]) {
        baseUrl = changes["access-token"].newValue;
        didChange = true;
    }

    if (didChange) {
        await populateRemoteTabs();
    }
});


/**
 * @param {TokenReq} req
 * @returns {Promise<string>}
 */
async function getTokenR(req) {
    const url = expect(baseUrl, "base url not yet set") + "/token";
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
 * @returns {Promise<PeersResp>}
 */
async function getPeersR() {
    const url = expect(baseUrl, "base url not yet set") + "/get-peers";
    const r = await fetch(url, {
        method: "GET",
        headers: {
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    // TODO: parse json
    return r.json();
}

/**
 * @param {PushTabReq} req
 * @returns {Promise<string>}
 */
async function pushTabR(req) {
    const url = expect(baseUrl, "base url not yet set") + "/push-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    return r.text();
}

/**
 * @param {GrabTabReq} req
 * @returns {Promise<string>}
 */
async function grabTabR(req) {
    const url = expect(baseUrl, "base url not yet set") + "/grab-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    return r.text();
}


/***********************/
/****** UI models ******/
/***********************/


/**
 * @param {DragEvent} e
 * @param {TabInfo} tab
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

/**
 * @param {string} deviceName
 * @param {DragEvent} ev
 */
async function onDrop(deviceName, ev) {
    ev.preventDefault();
    // Since dragLeave doesn't fire in this case, we unset the hover
    dragModel.hoverPanes[deviceName] = false;

    // TODO: This fires on drops of anything, not just the tab, and some things we could accept

    if (dragModel.sourcePane !== deviceName && dragModel.tabData !== null && dragModel.sourcePane !== null) {
        console.log("Accepting drop to", deviceName, dragModel.tabData);
    } else {
        return;
    }

    // We have to copy it from global, otherwise the 'dragend' handler may fire
    // after the await point and overwrite them with null
    const tabData = dragModel.tabData;
    const sourcePane = dragModel.sourcePane;

    if (deviceName == "__LOCAL") {
        // Create tab on this device
        await browser.tabs.create({
            active: false,
            url: tabData.url,
        });
        await grabTabR(
            {target: sourcePane, tabId: tabData.identity},
        );
    } else {
        // Draw a grayed-out tab on remote device until it's received
        tabData.state = "grayed";
        const targetDevice = remoteDeviceModel.devices.find(d => d.name === deviceName);
        if (targetDevice) {
            targetDevice.tabs.push(tabData);
        }

        await pushTabR(
            {target: deviceName, tab: tabData},
        );
        if (sourcePane == "__LOCAL") {
            const tabId = parseInt(tabData.identity);
            if (isNaN(tabId)) {
                panic("Local tab id is invalid");
            }
            await browser.tabs.remove(tabId);
        } else {
            await grabTabR(
                {target: sourcePane, tabId: tabData.identity},
            );
        }
        // Enqueue populating remote tabs
        populateRemoteTabs();
    }
}


/** @type {{ tabs: TabInfo[] }} */
let localTabModel = { tabs: [] };
/** @type {{ devices: { name: string, tabs: TabInfo[] }[] }} */
let remoteDeviceModel = { devices: [] };
/** @type {{ hoverPanes: {[name: string]: boolean}, sourcePane: string | null, tabData: TabInfo | null }} */
let dragModel = { hoverPanes: {}, sourcePane: null, tabData: null };

/**
 * @param {browser.tabs.Tab[]=} mbQueried
 */
async function populateLocalTabs(mbQueried) {
    const tabs = mbQueried || await browser.tabs.query({});
    let tabModel = [];
    for (const tab of tabs) {
        tabModel.push({
            title: expect(tab.title, "no permissions for title"),
            url: expect(tab.url, "no permissions for url"),
            favicon: tab.favIconUrl || null,
            identity: expect(tab.id, "no permission for id").toString(),
        });
    }
    localTabModel.tabs = tabModel;
}

let lastPopulated = Date.now() - 1000;
let /** @type {number | null} */ timerId = null;
async function populateRemoteTabs() {
    // Prevent being requested too much
    const now = Date.now();
    const diff = now - lastPopulated;
    if (diff < 1000) {
        if (!timerId) {
            // Enqueue execution
            const toWait = 1000 - diff;
            timerId = setTimeout(() => {
                // reset the timer and call it again
                timerId = null;
                populateRemoteTabs();
            }, toWait);
        }
        return;
    }
    lastPopulated = now;

    const resp = await getPeersR();
    remoteDeviceModel.devices = resp.peers;
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
        onDrop,

        openOptions: () => { browser.runtime.openOptionsPage() },
    }));
});

// Populate tabs model initially, update it every time tabs change
populateLocalTabs();
browser.tabs.onCreated.addListener(() => populateLocalTabs());
browser.tabs.onUpdated.addListener(() => populateLocalTabs(), {properties: ["title"]})
browser.tabs.onRemoved.addListener(async () => {
    // Since when the event is fired, the tab is not yet removed, we query the
    // tabs several times with a delay to hopefully catch it
    for (let i = 0; i < 10; ++i) {
        await sleep(100);
        const newTabs = await browser.tabs.query({});
        if (newTabs.length !== localTabModel.tabs.length) {
            await populateLocalTabs(newTabs);
            return;
        }
    }
});

// populateRemoteTabs();
// setInterval(populateRemoteTabs, 5000);
