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


/** @typedef {{username: string, password: string}} TokenReq */
/** @typedef {{url: string, identity: string, title: string}} TabInfo */
/** @typedef {{title: string, identity: number, tabs: TabInfo[]}} WindowInfo */
/** @typedef {{name: string, windows: WindowInfo[]}} PeerInfo */
/** @typedef {{url: string, windowId: number}} PushedTab */
/** @typedef {{windows: WindowInfo[]}} NotifyTabReq */
/** @typedef {{tabs: PushedTab[]}} NotifyTabResp */


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
 * @returns {Promise<WindowInfo[]>}
 */
async function buildState() {
    const windows = await browser.windows.getAll({populate: true});
    let ws = [];
    for (const w of windows) {
        const title = expect(w.title, "not enough tab permissions to get window title");
        const identity = expect(w.id, "not enough tab persmissions to get window id");
        let ts = [];
        const tabs = expect(w.tabs, "not enough tab permissions to get window tabs");
        for (const t of tabs) {
            ts.push({
                url: expect(t.url, "not enough tab permissions to get tab url"),
                identity: expect(t.id, "not enough tab permissions to get tab id").toString(),
                title: expect(t.title, "not enough tab permissions to get tab title"),
            })
        }
        ws.push({
            title,
            identity,
            tabs: ts,
        });
    }
    return ws;
}

// periodically notify the server about our tab state
browser.alarms.onAlarm.addListener(async (a) => {
    if (token === null)  return;
    if (a.name !== "tab-notify")  return;

    const windows = await buildState();

    const req = { windows };
    const resp = await updateTabs(baseUrl, token, req);

    // create new received tabs
    for (const tab of resp.tabs) {
        await browser.tabs.create({
            active: false,
            url: tab.url,
            windowId: tab.windowId,
        });
    }
});
browser.alarms.create("tab-notify", {periodInMinutes: 0.25});
