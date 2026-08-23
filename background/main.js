/// <reference path="../types/webext.d.ts" />


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
 *      url: string,
 *      tabId: string,
 *  }} PushedTab
 */

/** @typedef {{
 *      tabId: string,
 *  }} GrabbedTab
 */

/** @typedef {{
 *      name: string,
 *      tabs: TabInfo[],
 *  }} PeerInfo
 */

/** @typedef {{
 *      tabs: TabInfo[],
 *  }} NotifyTabsReq
 */

/** @typedef {{
 *      pushedTabs: PushedTab[],
 *      grabbedTabs: GrabbedTab[],
 *  }} NotifyTabsResp
 */

/** @typedef {{
 *      pushedTabs: string[],
 *      grabbedTabs: string[],
 *      tabs: TabInfo[],
 *  }} AckReq
 */


/*********************************/
/****** Request definitions ******/
/*********************************/


/**
 * @param {string} username
 * @param {string} password
 * @returns {Promise<string>}
 */
async function getToken(username, password) {
    const url = baseUrl + "/token";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify({username, password}),
        headers: {
            "Content-Type": "application/json",
        },
    });
    return r.text()
}

/**
 * @param {NotifyTabsReq} req
 * @returns {Promise<NotifyTabsResp>}
 */
async function notifyR(req) {
    const url = expect(baseUrl, "base url not yet set") + "update";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    if (!r.ok) {
        throw new Error("/update failed: " + await r.text());
    }
    // TODO parse json
    return await r.json();
}

/**
 * @param {AckReq} req
 * @returns {Promise<string>}
 */
async function acknowledgeR(req) {
    const url = expect(baseUrl, "base url not yet set") + "acknowledge";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": expect(accessToken, "token not yet set"),
        },
    });
    if (!r.ok) {
        throw new Error("/acknowledge failed: " + await r.text());
    }
    return await r.text();
}


/****************************/
/****** Main extension ******/
/****************************/


// Token and url are stored in the settings, without them set nothing works
/** @type {string | null} */
let baseUrl = null; // TODO idk
/** @type {string | null} */
let accessToken = null;
browser.storage.local.get(["remote-url", "access-token"]).then(async r => {
    baseUrl = r["remote-url"];
    accessToken = r["access-token"];
});
browser.storage.onChanged.addListener(async (changes, areaName) => {
    if (areaName !== "local")  return;

    if (changes["remote-url"]) {
        baseUrl = changes["remote-url"].newValue;
    }
    if (changes["access-token"]) {
        accessToken = changes["access-token"].newValue;
    }
});


// set the script button to open the manager
browser.browserAction.onClicked.addListener(() => {
    browser.tabs.create({
        url: "/ui/manager.html"
    });
});

/**
 * @returns {Promise<TabInfo[]>}
 */
async function buildState() {
    const localTabs = await browser.tabs.query({});
    let tabs = [];
    for (const tab of localTabs) {
        tabs.push({
            url: expect(tab.url, "not enough tab permissions to get tab url"),
            identity: expect(tab.id, "not enough tab permissions to get tab id").toString(),
            title: expect(tab.title, "not enough tab permissions to get tab title"),
            favicon: tab.favIconUrl || null,
            inFlight: false,
        })
    }
    return tabs;
}

/** @type { Record<string, number> } */
let recentlyAcked = {};
async function notifyLocalTabs() {
    const currentTabs = await buildState();
    const updates = await notifyR({ tabs: currentTabs });

    // Acked tabs are remembered for a minute for idempotency
    const now = Date.now();
    // Filter a dict, yeah it looks like this
    recentlyAcked = Object.fromEntries(
        Object.entries(recentlyAcked)
            .filter(([_id, time]) => now - time < 60_000)
    );

    // Create pushed tabs
    let pushedTabs = [];
    let grabbedTabs = [];
    for (const tab of updates.pushedTabs) {
        if (!(tab.tabId in recentlyAcked)) {
            await browser.tabs.create({
                active: false,
                url: tab.url,
            });
        }
        pushedTabs.push(tab.tabId);
        recentlyAcked[tab.tabId] = now;
    }
    // Remove grabbed tabs
    for (const tab of updates.grabbedTabs) {
        // TODO buffer of acked TODO what did I mean by that?
        const tabId = parseInt(tab.tabId);
        if (!(tab.tabId in recentlyAcked)) {
            if (!isNaN(tabId)) {
                try {
                    await browser.tabs.remove(tabId);
                } catch (e) {
                    console.log("Error removing tab", e);
                }
            }
        }
        grabbedTabs.push(tab.tabId);
        recentlyAcked[tab.tabId] = now;
    }
    // Acknowledge the in flights with new tab state
    const tabs = await buildState();
    if (pushedTabs.length !== 0 || grabbedTabs.length !== 0) {
        await acknowledgeR({pushedTabs, grabbedTabs, tabs});
    }
}

// periodically notify the server about our tab state
browser.alarms.onAlarm.addListener(async (a) => {
    if (accessToken === null)  return;
    if (a.name !== "tab-notify")  return;

    await notifyLocalTabs();
});
browser.alarms.create("tab-notify", {periodInMinutes: 0.25});

// TODO these should be in the background script
notifyLocalTabs();
setInterval(notifyLocalTabs, 5000);
