// Define Alpine types that we use
/** @type {{ reactive: <T>(v: T) => T, data: <T>(name: string, fn: () => T) => void }} */
// const Alpine = /** @type {any} */ (globalThis).Alpine;


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

document.addEventListener("alpine:init", () => {
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
