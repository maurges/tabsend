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
 *      inFlight: boolean,
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
        accessToken = changes["access-token"].newValue;
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
    const url = expect(baseUrl, "base url not yet set") + "token";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
        },
    });
    if (!r.ok) {
        throw new Error("/token failed: " + await r.text());
    }
    return await r.text();
}

/**
 * @returns {Promise<PeersResp>}
 */
async function getPeersR() {
    const url = expect(baseUrl, "base url not yet set") + "get-peers";
    const r = await fetch(url, {
        method: "GET",
        headers: {
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    if (!r.ok) {
        throw new Error("/get-peers failed: " + await r.text());
    }
    // TODO: parse json
    return await r.json();
}

/**
 * @param {PushTabReq} req
 * @returns {Promise<string>}
 */
async function pushTabR(req) {
    const url = expect(baseUrl, "base url not yet set") + "push-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    if (!r.ok) {
        throw new Error("/push-tab failed: " + await r.text());
    }
    return await r.text();
}

/**
 * @param {GrabTabReq} req
 * @returns {Promise<string>}
 */
async function grabTabR(req) {
    const url = expect(baseUrl, "base url not yet set") + "grab-tab";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    if (!r.ok) {
        throw new Error("/grab-tab failed: " + await r.text());
    }
    return await r.text();
}


/***********************/
/****** UI models ******/
/***********************/


let localTabModel = {
    /** @type {TabInfo[]} */
    tabs: []
};
let remoteDeviceModel = {
    /** @type {{ name: string, tabs: TabInfo[] }[]} */
    devices: []
};
let dragModel = {
    /** @type {Record<string, boolean>} */
    hoverPanes: {},
    /** @type {string | null} */
    sourcePane: null,
    /** @type {TabInfo | null} */
    tabData: null
};
let sendDeviceModel = {
    /** @type {{name: string, prettyName?: string }[]} */
    devices: [],
    /** @type {string | null} */
    sourcePane: null,
    /** @type {TabInfo | null} */
    tabData: null,

    positioned: false,
    /** @type {string} */
    posTop: "0px",
    /** @type {string} */
    posLeft: "0px",
}


/***********************/
/****** UI actions ******/
/***********************/

/**
 * @param {TabInfo} tab
 * @param {string} deviceName
 */
async function onClose(tab, deviceName) {
    if (deviceName === "__LOCAL") {
        const tabId = parseInt(tab.identity);
        if (isNaN(tabId)) {
            panic("Local tab id is invalid");
        }
        browser.tabs.remove(tabId);
    } else {
        await grabTabR(
            {target: deviceName, tabId: tab.identity},
        );
    }
}

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
        // Drag in progress by us, drop to a pane that is not the source
    } else {
        return;
    }

    // We have to copy it from global, otherwise the 'dragend' handler may fire
    // after the await point and overwrite them with null
    const tabData = dragModel.tabData;
    const sourcePane = dragModel.sourcePane;

    await transferTab(sourcePane, deviceName, tabData);
}

/**
 * @param {PointerEvent} ev
 * @param {TabInfo} tab
 * @param {string} originName
 * @param {HTMLElement} elem - the context meny element
 * @param {"right" | "left"} mouse - the button this was pressed with, for mobile support
 */
function onContextMenu(ev, tab, originName, elem, mouse) {
    // Right click is allowed on all, left click only on touch input
    if (mouse === "left" && ev.pointerType !== "touch") {
        return;
    }

    ev.preventDefault();

    sendDeviceModel.sourcePane = originName;
    sendDeviceModel.tabData = tab;

    // Populate the device list with valid targets
    sendDeviceModel.devices = [{name: "__LOCAL"}].concat(remoteDeviceModel.devices).filter(d => d.name != originName);
    if (originName != "__LOCAL") {
        // A presentable name for the local device. It's always at position 0
        expect(sendDeviceModel.devices[0], "Local device missing somehow").prettyName = "This device";
    }

    // Position dropdown relative to the click
    let top = ev.clientY;
    let left = ev.clientX;
    // TODO: prevent it going off screen somehow

    sendDeviceModel.posTop = top + "px";
    sendDeviceModel.posLeft = left + "px";
    elem.showPopover();
    // Adjust the position if the element doesn't fit in the bottom or right.
    // Done on the next tick after being shown, which means the bounding box is
    // already computed. The positioned value affects the css 'visibility' to
    // prevent flickering
    sendDeviceModel.positioned = false;
    /** @type {{ nextTick: (cb: () => void) => void }} */
    const Alpine = /** @type {any} */ (globalThis).Alpine;
    Alpine.nextTick(() => {
        const rect = elem.getBoundingClientRect();
        if (rect.right > window.innerWidth) {
            sendDeviceModel.posLeft = Math.max(0, ev.clientX - rect.width) + "px";
        }
        if (rect.bottom > window.innerHeight) {
            sendDeviceModel.posTop = Math.max(0, ev.clientY - rect.height) + "px";
        }
        sendDeviceModel.positioned = true;
    });
}

/**
 * @param {string} deviceName
 */
async function onContextMenuSend(deviceName) {
    const sourceDevice = expect(sendDeviceModel.sourcePane, "Invalid context menu state (pane)");
    const tabData = expect(sendDeviceModel.tabData, "Invalid context menu state (tab)")
    await transferTab(sourceDevice, deviceName, tabData);
}

/**
 * @param {string} sourceDeviceName
 * @param {string} targetDeviceName
 * @param {TabInfo} tabData
 */
async function transferTab(sourceDeviceName, targetDeviceName, tabData) {
    if (targetDeviceName == "__LOCAL") {
        // Create tab on this device
        await browser.tabs.create({
            active: false,
            url: tabData.url,
        });
        await grabTabR(
            {target: sourceDeviceName, tabId: tabData.identity},
        );
    } else {
        // Draw a grayed-out tab on remote device until it's received
        const targetDevice = remoteDeviceModel.devices.find(d => d.name === targetDeviceName);
        if (targetDevice) {
            // Clone fucking doesn't work
            const tab = {
                url: tabData.url,
                identity: tabData.identity,
                title: tabData.title,
                favicon: tabData.favicon,
                inFlight: true,
            }
            targetDevice.tabs.push(tab);
        }

        await pushTabR(
            {target: targetDeviceName, tab: tabData},
        );
        if (sourceDeviceName == "__LOCAL") {
            const tabId = parseInt(tabData.identity);
            if (isNaN(tabId)) {
                panic("Local tab id is invalid");
            }
            await browser.tabs.remove(tabId);
        } else {
            // Draw it grayed-out on remote source until it's acknowledged
            tabData.inFlight = true;

            await grabTabR(
                {target: sourceDeviceName, tabId: tabData.identity},
            );
        }
        // Enqueue populating remote tabs
        populateRemoteTabs();
    }
}

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
            inFlight: false,
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
    remoteDeviceModel = Alpine.reactive(remoteDeviceModel);
    dragModel = Alpine.reactive(dragModel);
    sendDeviceModel = Alpine.reactive(sendDeviceModel);

    Alpine.data("app", () => ({
        localTabModel,
        remoteDeviceModel,
        dragModel,
        sendDeviceModel,

        onClose,
        onDragStart,
        onDragEnd: () => {
            dragModel.sourcePane = null;
            dragModel.tabData = null;
        },
        onContextMenu,
        onContextMenuSend,
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

populateRemoteTabs();
setInterval(populateRemoteTabs, 5000);
