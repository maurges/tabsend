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
 *  }} TabInfo
 */

/** @typedef {{
 *      name: string,
 *      tabs: TabInfo[],
 *  }} PeerInfo
 */

/** @typedef {{
 *      url: string,
 *  }} PushedTab
 */

/** @typedef {{
 *      tabs: TabInfo[],
 *  }} NotifyTabReq
 */
/** @typedef {{
 *      tabs: PushedTab[],
 *  }} NotifyTabResp
 */


/*********************************/
/****** Request definitions ******/
/*********************************/


/**
 * @param {string} baseUrl
 * @param {string} username
 * @param {string} password
 * @returns {Promise<string>}
 */
async function getToken(baseUrl, username, password) {
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
 * @param {string} baseUrl
 * @param {string} authToken
 * @param {NotifyTabReq} req
 * @returns {Promise<NotifyTabResp>}
 */
async function updateTabs(baseUrl, authToken, req) {
    const url = baseUrl + "/update";
    const r = await fetch(url, {
        method: "POST",
        body: JSON.stringify(req),
        headers: {
            "Content-Type": "application/json",
            "X-Tabsend-Auth": authToken,
        },
    });
    return r.json(); // TODO proper parsing
}


/****************************/
/****** Main extension ******/
/****************************/


const username = "user";
const password = "password";
const baseUrl = "http://localhost:31337"; // TODO should be set in config
/** @type {string | null} */
let token = null;

// fetch the token from the server
getToken(baseUrl, username, password)
    .then(t => { token = t });

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
            favicon: expect(tab.favIconUrl, "not enough tab permissions to get tab favicon"),
        })
    }
    return tabs;
}

// periodically notify the server about our tab state
browser.alarms.onAlarm.addListener(async (a) => {
    if (token === null)  return;
    if (a.name !== "tab-notify")  return;

    const tabs = await buildState();

    const req = { tabs };
    const resp = await updateTabs(baseUrl, token, req);

    // create new received tabs
    for (const tab of resp.tabs) {
        await browser.tabs.create({
            active: false,
            url: tab.url,
        });
    }
});
browser.alarms.create("tab-notify", {periodInMinutes: 0.25});
