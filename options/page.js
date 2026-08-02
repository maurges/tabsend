/// <reference path="../types/webext.d.ts" />

/**
 * @param {string} s
 * @returns {never}
 */
function panic(s) {
    throw new Error("Panic: " + s);
}

/**
 * @template {HTMLElement} T
 * @param {string} id
 * @returns {T}
 */
function byId(id) {
    const r = document.getElementById(id);
    if (!r) {
        panic(`${id} not found`);
    }
    return /** @type {T} */ (r);
}

/** Debounce for an event handler
 * @template {(...args: any[]) => any} T
 * @param {T} func
 * @param {number} delay
 * @returns {(...args: Parameters<T>) => void}
 */
function debounce(func, delay) {
    /** @type {number | undefined} */
    let timeoutId;
    /** @this {ThisParameterType<T>} */
    return function(...args) {
        clearTimeout(timeoutId);
        timeoutId = setTimeout(() => {
            func.apply(this, args);
        }, delay);
    };
}


let urlModel = {
    isSet: false,
    didFail: false,
};


async function urlChanged() {
    let input = inputUrl.value;
    if (!input.startsWith("http")) {
        input = "http://" + input;
    }

    let url;
    try {
        url = new URL(input);
    } catch {
        console.log("Invalid url TODO notify user");
        return;
    }
    const remoteUrl = url.toString();

    // Firefox doesn't handle port correctly when requesting the permissions,
    // but it seems to be ignored when matching
    const matchPattern = url.toString() + "*";
    url.port = "";
    const matchPatternNoPort = url.toString() + "*";

    const r = await browser.permissions.request({
        origins: [matchPattern, matchPatternNoPort],
    });
    if (r) {
        await browser.storage.local.set({"remote-url": remoteUrl});
    } else {
        console.log("Permission denied on url TODO notify user");
    }
}

/**
 * @param {Event} ev
 */
function tokenChanged(ev) {
    const elem = /** @type {HTMLInputElement} */ (ev.target);
    browser.storage.local.set({"access-token": elem.value});
}

/** @type {HTMLInputElement} */
const inputUrl = byId("input-url");
/** @type {HTMLInputElement} */
const inputToken = byId("input-token");

inputToken.addEventListener("input", debounce(tokenChanged, 1000));

// populate the two fields initially
browser.storage.local.get(["remote-url", "access-token"]).then(async r => {
    inputUrl.value = r["remote-url"] || "";
    inputToken.value = r["access-token"] || "";
});

document.addEventListener("alpine:init", () => {
    // Define Alpine types that we use for typescript checking
    /** @type {{ reactive: <T>(v: T) => T, data: <T>(name: string, fn: () => T) => void }} */
    const Alpine = /** @type {any} */ (globalThis).Alpine;

    urlModel = Alpine.reactive(urlModel);

    Alpine.data("app", () => ({
        urlModel,

        urlChanged,
        tokenChanged: debounce(tokenChanged, 1000),
    }));
});
