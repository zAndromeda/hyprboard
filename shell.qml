// Clipboard canvas for Quickshell + Hyprland
//
//  * hover the top-right corner  -> peek (top-right quarter of the screen)
//  * drag the grip (top-left of the panel) down/left -> pinned (right half, stays)
//  * drag a pinned panel's grip back to the top-right corner -> hides
//  * the widget runs its own wl-paste watchers, so every copy shows up live
//
// Install:  ~/.config/quickshell/clip/{shell.qml,Pill.qml}      Run:  qs -c clip

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root

    // ================================================================ palette
    // wallpaper colours come from a pywal-format file (pywal / wallust / matugen template)
    property var wal: null
    property bool useWallpaper: true
    readonly property bool wallOn: useWallpaper && wal !== null
    readonly property color walBg: wal ? Qt.color(wal.special.background) : "#1d1d20"
    readonly property color walFg: wal ? Qt.color(wal.special.foreground) : "#ececef"

    readonly property color cBg: wallOn ? Qt.rgba(walBg.r, walBg.g, walBg.b, 0.94) : "#f01d1d20"
    readonly property color cDot: wallOn ? Qt.rgba(walFg.r, walFg.g, walFg.b, 0.2) : "#33ffffff"
    readonly property color cPanel: wallOn
        ? Qt.rgba(Math.min(1, walBg.r + 0.06), Math.min(1, walBg.g + 0.06), Math.min(1, walBg.b + 0.06), 0.96)
        : "#f22b2b30"
    readonly property color cRing: wallOn ? Qt.rgba(walFg.r, walFg.g, walFg.b, 0.12) : "#1fffffff"
    readonly property color cFg: wallOn ? walFg : "#ececef"
    readonly property color cMute: wallOn ? Qt.rgba(walFg.r, walFg.g, walFg.b, 0.55) : "#8d8d96"
    readonly property color cAcc: wallOn ? Qt.color(wal.colors.color4) : "#8fb0ff"
    readonly property color cCode: wallOn ? Qt.color(wal.colors.color2) : "#b7e4c7"
    readonly property color cDanger: "#ff6b6b"
    readonly property var pal: ({ fg: cFg, mute: cMute, acc: cAcc, ring: cRing, danger: cDanger })

    FileView {
        id: walFile
        path: Quickshell.env("HOME") + "/.cache/wal/colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const o = JSON.parse(text());
                root.wal = (o.special && o.colors) ? o : null;
            } catch (e) { root.wal = null; }
        }
        onLoadFailed: root.wal = null
    }

    // ================================================================ state
    property int mode: 0                 // 0 hidden, 1 peek (quarter), 2 pinned (right half)
    property var screenTarget: Quickshell.screens[0]
    property string layoutScreen: ""     // screen whose layout is currently applied
    readonly property real scrW: screenTarget ? screenTarget.width : 1920
    readonly property real scrH: screenTarget ? screenTarget.height : 1080

    property bool dragging: false        // grip drag
    property real liveW: 0
    property real liveH: 0
    readonly property real targetW: mode === 0 ? 0 : scrW / 2
    readonly property real targetH: mode === 0 ? 0 : (mode === 1 ? scrH / 2 : scrH)
    property real panelW: dragging ? liveW : targetW
    property real panelH: dragging ? liveH : targetH
    Behavior on panelW { enabled: !root.dragging; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    Behavior on panelH { enabled: !root.dragging; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

    property bool busy: false            // an item is being dragged / resized / panned
    property bool grace: false
    property bool touched: false         // once you click anything, the peek stays open until you close it
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    property string selectedId: ""
    property string editingId: ""
    property string query: ""
    property bool settingsOpen: false
    property bool confirmOpen: false
    property int zTop: 1
    property string toastText: ""

    // settings (persisted)
    property bool avoidOverlap: true
    property bool autoPaste: false

    // persisted data
    property var hidden: ({})            // cliphist ids that were pinned/edited into local items
    property var layoutsByScreen: ({})
    property var viewsByScreen: ({})

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell-clip"
    readonly property string pinsDir: stateDir + "/pins"
    readonly property string thumbDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/clipthumbs"
    // shell helper: mk SRC DST  -> png thumbnail capped at 1200px (falls back to a plain copy)
    readonly property string thumbFn:
        "mk(){ if command -v magick >/dev/null 2>&1; then magick \"$1[0]\" -thumbnail '1200x1200>' \"png:$2\"; " +
        "elif command -v convert >/dev/null 2>&1; then convert \"$1[0]\" -thumbnail '1200x1200>' \"png:$2\"; " +
        "else cp \"$1\" \"$2\"; fi; }; "

    ListModel { id: clips }

    function row(o) {
        return Object.assign({
            cid: "", local: false, kind: "text", preview: "", body: "", label: "", pinned: false,
            imgSrc: "", imgOrig: "", thumbOk: false, ready: false,
            px: 0, py: 0, pw: 0, ph: 0, ps: 1, pr: 0, pz: 0, mw: 0, mh: 0
        }, o);
    }

    // ================================================================ open / close
    function focusedScreen() {
        const n = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        for (const s of Quickshell.screens) if (s.name === n) return s;
        return Quickshell.screens[0];
    }
    function show(screen) {
        if (mode !== 0) return;
        if (screen) screenTarget = screen;
        switchScreen(screenTarget.name);
        grace = true;
        touched = false;
        graceTimer.restart();
        mode = 1;
    }
    function hide() {
        mode = 0;
        selectedId = ""; editingId = ""; settingsOpen = false; confirmOpen = false;
    }
    onModeChanged: if (mode === 0) persist()

    Timer { id: graceTimer; interval: 1500; onTriggered: root.grace = false }
    Timer {
        id: hideTimer
        interval: 450
        running: root.mode === 1 && !root.grace && !root.touched && !panelHover.hovered && !root.busy && !root.dragging
                 && !root.settingsOpen && !root.confirmOpen && root.editingId === "" && !search.activeFocus
        onTriggered: root.hide()
    }

    IpcHandler {
        target: "clip"
        function toggle(): void { if (root.mode === 0) root.show(root.focusedScreen()); else root.hide(); }
        function pin(): void { if (root.mode === 0) root.show(root.focusedScreen()); root.mode = 2; }
        function hide(): void { root.hide(); }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; right: true }
            implicitWidth: 14
            implicitHeight: 14
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "clipcorner"
            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: root.show(modelData) }
        }
    }

    // ================================================================ live capture
    // The widget owns capture: every copy (Ctrl+C, Ctrl+Shift+C, "Copy" buttons...) fires
    // wl-paste --watch, which stores it in cliphist and prints a line that refreshes the canvas.
    Process {
        running: true
        command: ["wl-paste", "--type", "text", "--watch", "sh", "-c", "cliphist -max-items 50 store; echo t"]
        stdout: SplitParser { onRead: liveTimer.restart() }
    }
    Process {
        running: true
        command: ["wl-paste", "--type", "image", "--watch", "sh", "-c", "cliphist -max-items 50 store; echo i"]
        stdout: SplitParser { onRead: liveTimer.restart() }
    }
    Timer { id: liveTimer; interval: 180; onTriggered: root.refresh() }

    // ================================================================ helpers
    function kindOf(s) {
        const t = s.trim();
        if (/^#[0-9a-fA-F]{6}$/.test(t)) return "color";
        if (/^https?:\/\/\S+$/.test(t)) return "link";
        if (/^(#{1,3} |[-*] |\d+\. |> |```)/m.test(s) || /\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\)/.test(s)) return "md";
        if (/^(sudo |git |cd |ls |npm |pip |ssh |curl |docker |\$ |exec-once|bind\s*=)/m.test(t) || /[{};]\s*$/m.test(t)) return "code";
        return "text";
    }
    function idxOf(cid) {
        for (let i = 0; i < clips.count; i++) if (clips.get(i).cid === cid) return i;
        return -1;
    }
    function matchesItem(c) {
        const q = root.query.trim().toLowerCase();
        if (q === "") return true;
        return ((c.body !== "" ? c.body : c.preview) + " " + c.kind + " " + c.label).toLowerCase().indexOf(q) >= 0;
    }
    function toast(t) { toastText = t; toastTimer.restart(); }
    Timer { id: toastTimer; interval: 1100; onTriggered: root.toastText = "" }

    // ================================================================ cliphist sync
    property bool listAgain: false
    function refresh() {
        if (listProc.running) listAgain = true;
        else listProc.running = true;
    }
    Process {
        id: listProc
        command: ["sh", "-c", "cliphist list | head -n 50"]
        stdout: StdioCollector { onStreamFinished: root.mergeList(text) }
        onExited: if (root.listAgain) { root.listAgain = false; running = true; }
    }

    function mergeList(txt) {
        const rows = [], present = {};
        for (const line of txt.split("\n")) {
            if (!line) continue;
            const t = line.indexOf("\t");
            if (t < 0) continue;
            const cid = line.slice(0, t), prev = line.slice(t + 1);
            const isImg = /^\[\[ binary data/.test(prev);
            let label = "";
            if (isImg) {
                const m = prev.match(/binary data \S+ \S+ (\w+) (\d+x\d+)/);
                if (m) label = m[1] + " · " + m[2];
            }
            present[cid] = true;
            rows.push({ cid: cid, isImg: isImg, prev: prev, label: label });
        }

        // drop entries cliphist no longer has (local/pinned ones stay)
        for (let i = clips.count - 1; i >= 0; i--) {
            const c = clips.get(i);
            if (!c.local && !present[c.cid]) {
                if (selectedId === c.cid) selectedId = "";
                clips.remove(i);
            }
        }
        const have = {};
        for (let i = 0; i < clips.count; i++) have[clips.get(i).cid] = true;

        const newText = [], newImg = [];
        for (const r of rows) {
            if (have[r.cid] || root.hidden[r.cid]) continue;
            clips.append(row({
                cid: r.cid, kind: r.isImg ? "image" : kindOf(r.prev), preview: r.prev, label: r.label,
                imgSrc: r.isImg ? root.thumbDir + "/" + r.cid + ".png" : ""
            }));
            (r.isImg ? newImg : newText).push(r.cid);
        }
        for (const k in root.hidden) if (!present[k]) delete root.hidden[k];

        queueText(newText);
        queueImg(newImg);
        ensurePlaced();
        scheduleResolve("");
    }

    // full text bodies (list only gives a short one-line preview)
    property var textQueue: []
    function queueText(ids) { if (ids.length) { textQueue = textQueue.concat(ids); runText(); } }
    function runText() {
        if (textProc.running || textQueue.length === 0) return;
        const ids = textQueue.slice(0, 40);
        textQueue = textQueue.slice(40);
        textProc.command = ["sh", "-c",
            "for id in \"$@\"; do printf '\\036%s\\037' \"$id\"; cliphist decode \"$id\" 2>/dev/null | head -c 6000; done",
            "sh"].concat(ids);
        textProc.running = true;
    }
    Process {
        id: textProc
        stdout: StdioCollector {
            onStreamFinished: {
                for (const part of text.split("\x1e")) {
                    if (!part) continue;
                    const k = part.indexOf("\x1f");
                    if (k < 0) continue;
                    const cid = part.slice(0, k), body = part.slice(k + 1);
                    const i = root.idxOf(cid);
                    if (i < 0) continue;
                    clips.setProperty(i, "body", body);
                    clips.setProperty(i, "kind", root.kindOf(body));
                }
            }
        }
        onExited: root.runText()
    }

    // thumbnails, capped at 1200px so huge screenshots stay cheap
    property var imgQueue: []
    property var imgBatch: []
    function queueImg(ids) { if (ids.length) { imgQueue = imgQueue.concat(ids); runImg(); } }
    function runImg() {
        if (imgProc.running || imgQueue.length === 0) return;
        imgBatch = imgQueue.slice(0, 8);
        imgQueue = imgQueue.slice(8);
        imgProc.command = ["sh", "-c",
            root.thumbFn + "d=\"$1\"; shift; mkdir -p \"$d\"; for id in \"$@\"; do f=\"$d/$id.png\"; " +
            "[ -s \"$f\" ] && continue; cliphist decode \"$id\" > \"$d/.$id.raw\" 2>/dev/null && mk \"$d/.$id.raw\" \"$f\"; rm -f \"$d/.$id.raw\"; done",
            "sh", root.thumbDir].concat(imgBatch);
        imgProc.running = true;
    }
    Process {
        id: imgProc
        onExited: {
            for (const cid of root.imgBatch) {
                const i = root.idxOf(cid);
                if (i >= 0) clips.setProperty(i, "thumbOk", true);
            }
            root.runImg();
        }
    }

    // ================================================================ actions
    Process { id: copyProc }
    Process { id: delProc }
    Process { id: wipeProc }

    function copyClip(cid) {
        const i = idxOf(cid);
        if (i < 0) return;
        const c = clips.get(i);
        let script, arg;
        if (c.local && c.kind === "image") { script = "wl-copy < \"$1\""; arg = c.imgOrig; }
        else if (c.local) { script = "printf '%s' \"$1\" | wl-copy"; arg = c.body !== "" ? c.body : c.preview; }
        else {
            if (!/^\d+$/.test(cid)) return;
            script = "cliphist decode \"$1\" | wl-copy"; arg = cid;
        }
        if (autoPaste) script += "; sleep 0.25; wtype -M ctrl v -m ctrl";
        copyProc.command = ["sh", "-c", script, "sh", arg];
        copyProc.running = true;
        toast("Copied");
        if (autoPaste) hide();
    }

    function deleteClip(cid) {
        const i = idxOf(cid);
        if (i < 0) return;
        const c = clips.get(i);
        if (!c.local && /^\d+$/.test(cid)) {
            delProc.command = ["sh", "-c",
                "cliphist list | awk -F'\\t' -v id=\"$1\" '$1==id' | cliphist delete", "sh", cid];
            delProc.running = true;
        }
        clips.remove(i);
        if (selectedId === cid) selectedId = "";
        dirty.restart();
    }

    // turn a cliphist entry into a local one (survives cliphist's 50-item limit and wipes)
    property var pinQueue: []
    property string pinLid: ""
    function makeLocal(i, over) {
        const c = clips.get(i);
        const lid = "L" + Date.now() + Math.floor(Math.random() * 1000);
        const isImg = c.kind === "image";
        const o = row(Object.assign({
            cid: lid, local: true, kind: c.kind, preview: c.body !== "" ? c.body : c.preview,
            body: c.body !== "" ? c.body : (isImg ? "" : c.preview), label: c.label, pinned: false,
            imgSrc: isImg ? root.pinsDir + "/" + lid + ".t.png" : "",
            imgOrig: isImg ? root.pinsDir + "/" + lid + ".png" : "",
            thumbOk: !isImg, ready: true,
            px: c.px, py: c.py, pw: c.pw, ph: c.ph, ps: c.ps, pr: c.pr, pz: c.pz, mw: c.mw, mh: c.mh
        }, over || {}));
        if (!c.local) root.hidden[c.cid] = true;
        if (isImg && !c.local && /^\d+$/.test(c.cid)) {
            pinQueue = pinQueue.concat([[lid, c.cid]]);
            runPin();
        } else if (isImg && c.local) {
            o.imgSrc = c.imgSrc; o.imgOrig = c.imgOrig; o.thumbOk = true;
        }
        clips.set(i, o);
        if (selectedId === c.cid) selectedId = lid;
        dirty.restart();
        return lid;
    }
    function runPin() {
        if (pinProc.running || pinQueue.length === 0) return;
        const j = pinQueue[0];
        pinQueue = pinQueue.slice(1);
        pinLid = j[0];
        pinProc.command = ["sh", "-c",
            root.thumbFn + "mkdir -p \"$1\"; cliphist decode \"$2\" > \"$1/$3.png\" && mk \"$1/$3.png\" \"$1/$3.t.png\"",
            "sh", root.pinsDir, j[1], j[0]];
        pinProc.running = true;
    }
    Process {
        id: pinProc
        onExited: {
            const i = root.idxOf(root.pinLid);
            if (i >= 0) clips.setProperty(i, "thumbOk", true);
            root.runPin();
        }
    }

    function togglePin(cid) {
        const i = idxOf(cid);
        if (i < 0) return;
        const c = clips.get(i);
        if (c.local) {
            clips.setProperty(i, "pinned", !c.pinned);
            if (!c.pinned) { clips.setProperty(i, "py", 40); clips.setProperty(i, "pz", ++zTop); }
        } else {
            const lid = makeLocal(i, { pinned: true, py: 40 });
            toast("Pinned");
        }
        scheduleResolve(cid);
        dirty.restart();
    }

    function commitEdit(cid, txt) {
        editingId = "";
        const i = idxOf(cid);
        if (i < 0) return;
        const c = clips.get(i);
        const old = c.body !== "" ? c.body : c.preview;
        if (txt === old) return;
        if (c.local) {
            if (txt.trim() === "") { deleteClip(cid); return; }
            clips.setProperty(i, "body", txt);
            clips.setProperty(i, "preview", txt);
            clips.setProperty(i, "kind", kindOf(txt));
        } else {
            if (txt.trim() === "") return;
            makeLocal(i, { body: txt, preview: txt, kind: kindOf(txt), pinned: false });
        }
        dirty.restart();
    }

    function addNote() {
        const lid = "L" + Date.now() + Math.floor(Math.random() * 1000);
        const cx = (panelClip.width / 2 - panX) / zoom - 90;
        const cy = (panelClip.height / 2 - panY) / zoom - 30;
        clips.append(row({ cid: lid, local: true, kind: "text", ready: true, thumbOk: true, px: cx, py: cy, pz: ++zTop }));
        selectedId = lid;
        editingId = lid;
        scheduleResolve(lid);
        dirty.restart();
    }

    function wipeAll() {
        wipeProc.command = ["sh", "-c", "cliphist wipe; rm -rf \"$1\" \"$2\"", "sh", root.thumbDir, root.pinsDir];
        wipeProc.running = true;
        clips.clear();
        hidden = {}; layoutsByScreen = {}; viewsByScreen = {};
        selectedId = ""; editingId = "";
        confirmOpen = false; settingsOpen = false;
        persist();
        toast("Everything wiped");
    }

    // ================================================================ layout
    function boxOf(c) { return { w: c.mw > 0 ? c.mw : 230, h: c.mh > 0 ? c.mh : 110 }; }

    function freeSpot(pinned, arr) {
        const aw = root.scrW / 2 * 1.2, ah = root.scrH;
        const hit = (x, y) => {
            for (const r of arr)
                if (x < r.x + r.w + 14 && x + 230 > r.x - 14 && y < r.y + r.h + 14 && y + 110 > r.y - 14) return true;
            return false;
        };
        if (pinned) {                       // pinned items live on a shelf along the top
            for (let x = 40; x < aw; x += 30) if (!hit(x, 50)) return { x: x, y: 50 };
        }
        const y0 = 170;
        let best = { x: 60, y: y0 }, bd = -1;
        for (let a = 0; a < 90; a++) {
            const x = 40 + Math.random() * (aw - 280), y = y0 + Math.random() * (ah - y0 - 120);
            if (!hit(x, y)) return { x: x, y: y };
            let d = 1e9;
            for (const r of arr) d = Math.min(d, Math.hypot(r.x - x, r.y - y));
            if (d > bd) { bd = d; best = { x: x, y: y }; }
        }
        return best;
    }

    function ensurePlaced() {
        if (layoutScreen === "") return;
        const L = layoutsByScreen[layoutScreen] || {};
        const arr = [];
        for (let i = 0; i < clips.count; i++) {
            const c = clips.get(i);
            if (c.ready) { const b = boxOf(c); arr.push({ x: c.px, y: c.py, w: b.w, h: b.h }); }
        }
        for (let i = 0; i < clips.count; i++) {
            const c = clips.get(i);
            if (c.ready) continue;
            const l = L[c.cid];
            let x, y;
            if (l) {
                x = l.px; y = l.py;
                clips.setProperty(i, "pw", l.pw); clips.setProperty(i, "ph", l.ph);
                clips.setProperty(i, "ps", l.ps); clips.setProperty(i, "pr", 0);
                clips.setProperty(i, "mw", l.mw || 0); clips.setProperty(i, "mh", l.mh || 0);
            } else {
                const p = freeSpot(c.pinned, arr);
                x = p.x; y = p.y;
                clips.setProperty(i, "pr", 0);
            }
            clips.setProperty(i, "px", x); clips.setProperty(i, "py", y);
            clips.setProperty(i, "ready", true);
            arr.push({ x: x, y: y, w: 230, h: 110 });
        }
    }

    // push overlapping items apart; the item you just moved (and pinned ones) hold their ground
    function resolve(domCid) {
        if (!avoidOverlap) return;
        const n = clips.count, pad = 14;
        if (n < 2) return;
        const a = [];
        for (let i = 0; i < n; i++) {
            const c = clips.get(i), b = boxOf(c);
            a.push({ i: i, cid: c.cid, x: c.px, y: c.py, w: b.w, h: b.h, pin: c.pinned, ox: c.px, oy: c.py });
        }
        for (let it = 0; it < 40; it++) {
            let moved = false;
            for (let p = 0; p < n; p++) for (let q = p + 1; q < n; q++) {
                const A = a[p], B = a[q];
                const ox = Math.min(A.x + A.w, B.x + B.w) - Math.max(A.x, B.x) + pad;
                const oy = Math.min(A.y + A.h, B.y + B.h) - Math.max(A.y, B.y) + pad;
                if (ox <= 0 || oy <= 0) continue;
                let wa = 0.5, wb = 0.5;
                const fa = A.cid === domCid, fb = B.cid === domCid;
                if (fa && !fb) { wa = 0; wb = 1; }
                else if (fb && !fa) { wa = 1; wb = 0; }
                else if (A.pin && !B.pin) { wa = 0; wb = 1; }
                else if (B.pin && !A.pin) { wa = 1; wb = 0; }
                if (ox < oy) {
                    const s = (A.x + A.w / 2) < (B.x + B.w / 2) ? -1 : 1;
                    A.x += s * ox * wa; B.x -= s * ox * wb;
                } else {
                    const s = (A.y + A.h / 2) < (B.y + B.h / 2) ? -1 : 1;
                    A.y += s * oy * wa; B.y -= s * oy * wb;
                }
                moved = true;
            }
            if (!moved) break;
        }
        for (const r of a) {
            if (Math.abs(r.x - r.ox) > 0.5) clips.setProperty(r.i, "px", r.x);
            if (Math.abs(r.y - r.oy) > 0.5) clips.setProperty(r.i, "py", r.y);
        }
        dirty.restart();
    }
    property string resolveDom: ""
    function scheduleResolve(cid) { resolveDom = cid; resolveTimer.restart(); }
    Timer { id: resolveTimer; interval: 260; onTriggered: root.resolve(root.resolveDom) }

    function fit() {
        if (clips.count === 0) return;
        let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (let i = 0; i < clips.count; i++) {
            const c = clips.get(i), b = boxOf(c);
            x0 = Math.min(x0, c.px); y0 = Math.min(y0, c.py);
            x1 = Math.max(x1, c.px + b.w); y1 = Math.max(y1, c.py + b.h);
        }
        const vw = scrW / 2, vh = Math.max(targetH, scrH / 2);
        const z = Math.min(vw / (x1 - x0 + 80), vh / (y1 - y0 + 80), 1);
        zoom = z;
        panX = (vw - (x1 - x0) * z) / 2 - x0 * z;
        panY = (vh - (y1 - y0) * z) / 2 - y0 * z;
    }

    // per-monitor layouts ---------------------------------------------------
    function snapshotLayout() {
        if (layoutScreen === "") return;
        const m = {};
        for (let i = 0; i < clips.count; i++) {
            const c = clips.get(i);
            if (!c.ready) continue;
            m[c.cid] = { px: c.px, py: c.py, pw: c.pw, ph: c.ph, ps: c.ps, pr: c.pr, mw: c.mw, mh: c.mh };
        }
        layoutsByScreen[layoutScreen] = m;
        viewsByScreen[layoutScreen] = { zoom: zoom, panX: panX, panY: panY };
    }
    function switchScreen(name) {
        if (layoutScreen === name) { ensurePlaced(); return; }
        snapshotLayout();
        layoutScreen = name;
        for (let i = 0; i < clips.count; i++) clips.setProperty(i, "ready", false);
        ensurePlaced();
        const v = viewsByScreen[name];
        if (v) { zoom = v.zoom; panX = v.panX; panY = v.panY; }
        else fit();
        scheduleResolve("");
    }

    // ================================================================ persistence
    FileView { id: store; path: root.stateDir + "/state.json"; blockLoading: true }
    Process { running: true; command: ["mkdir", "-p", root.stateDir, root.pinsDir] }
    Timer { id: dirty; interval: 400; onTriggered: root.persist() }

    function persist() {
        snapshotLayout();
        const local = [];
        for (let i = 0; i < clips.count; i++) {
            const c = clips.get(i);
            if (!c.local) continue;
            local.push({ cid: c.cid, kind: c.kind, text: c.body !== "" ? c.body : c.preview, label: c.label,
                         pinned: c.pinned, img: c.imgOrig, thumb: c.imgSrc });
        }
        store.setText(JSON.stringify({
            settings: { wallpaper: useWallpaper, avoid: avoidOverlap, autoPaste: autoPaste },
            hidden: hidden, local: local, layouts: layoutsByScreen, views: viewsByScreen
        }));
    }

    Component.onCompleted: {
        try {
            const o = JSON.parse(store.text());
            if (o.settings) {
                useWallpaper = o.settings.wallpaper !== false;
                avoidOverlap = o.settings.avoid !== false;
                autoPaste = !!o.settings.autoPaste;
            }
            hidden = o.hidden || {};
            layoutsByScreen = o.layouts || {};
            viewsByScreen = o.views || {};
            for (const l of (o.local || [])) {
                clips.append(row({
                    cid: l.cid, local: true, kind: l.kind, preview: l.text, body: l.text, label: l.label || "",
                    pinned: !!l.pinned, imgSrc: l.thumb || "", imgOrig: l.img || "", thumbOk: true
                }));
            }
        } catch (e) { /* first run: nothing saved yet */ }
        refresh();
    }

    // ================================================================ keyboard
    function selectedIndex() { return idxOf(selectedId); }
    function ensureVisible(i) {
        const c = clips.get(i), b = boxOf(c);
        const cx = (c.px + b.w / 2) * zoom + panX, cy = (c.py + b.h / 2) * zoom + panY;
        if (cx < 60 || cy < 60 || cx > panelClip.width - 60 || cy > panelClip.height - 60) {
            panX = panelClip.width / 2 - (c.px + b.w / 2) * zoom;
            panY = panelClip.height / 2 - (c.py + b.h / 2) * zoom;
        }
    }
    function navigate(dx, dy) {
        if (clips.count === 0) return;
        let cur = selectedIndex();
        if (cur < 0) {
            let bd = 1e18;
            for (let i = 0; i < clips.count; i++) {
                const c = clips.get(i);
                if (!matchesItem(c)) continue;
                const d = Math.hypot((c.px * zoom + panX) - panelClip.width / 2, (c.py * zoom + panY) - panelClip.height / 2);
                if (d < bd) { bd = d; cur = i; }
            }
            if (cur >= 0) { selectedId = clips.get(cur).cid; ensureVisible(cur); }
            return;
        }
        const c = clips.get(cur), cb = boxOf(c);
        const cx = c.px + cb.w / 2, cy = c.py + cb.h / 2;
        let best = -1, bs = 1e18;
        for (let i = 0; i < clips.count; i++) {
            if (i === cur) continue;
            const o = clips.get(i);
            if (!matchesItem(o)) continue;
            const ob = boxOf(o);
            const vx = o.px + ob.w / 2 - cx, vy = o.py + ob.h / 2 - cy;
            const fwd = vx * dx + vy * dy;
            if (fwd <= 0) continue;
            const score = fwd + 2 * Math.abs(vx * dy - vy * dx);
            if (score < bs) { bs = score; best = i; }
        }
        if (best >= 0) { selectedId = clips.get(best).cid; ensureVisible(best); }
    }

    // ================================================================ grip drag logic
    function dragMove(dx, dy) {
        if (mode === 1) {
            const pull = Math.max(0, dy, -dx);
            liveH = Math.min(scrH, scrH / 2 + pull);
            liveW = Math.max(0, scrW / 2 - Math.max(0, dx));
        } else {
            liveH = scrH;
            liveW = Math.max(0, Math.min(scrW / 2, scrW / 2 - Math.max(0, dx)));
        }
    }
    function dragEnd(dx, dy, px, py) {
        if (mode === 1) {
            if (liveW < scrW / 2 * 0.6 || dx > 140) mode = 0;
            else if (liveH > scrH / 2 + 90) mode = 2;
        } else if (mode === 2) {
            const nearCorner = (scrW - px) < 260 && py < 260;
            if (nearCorner || liveW < scrW / 4) mode = 0;
        }
    }

    // ================================================================ the panel
    PanelWindow {
        id: win
        screen: root.screenTarget
        visible: root.panelW > 2 && root.panelH > 2
        anchors { top: true; right: true }
        implicitWidth: root.scrW / 2
        implicitHeight: root.scrH
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region { item: panelClip }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "clipcanvas"
        // OnDemand: gets keys only after you click it, so hover-peeking never steals your typing
        WlrLayershell.keyboardFocus: root.mode > 0 ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        Item {
            id: panelClip
            anchors.top: parent.top
            anchors.right: parent.right
            width: root.panelW
            height: root.panelH
            clip: true

            HoverHandler { id: panelHover }
            // any press inside the panel means "I'm using it": stop auto-hiding (passive, doesn't eat clicks)
            PointHandler {
                acceptedButtons: Qt.AllButtons
                onActiveChanged: if (active) root.touched = true
            }

            Rectangle {
                x: 0; y: -24
                width: parent.width + 24
                height: parent.height + 24
                radius: 22
                color: root.cBg
                border.width: 1
                border.color: root.cRing
                Behavior on color { ColorAnimation { duration: 300 } }
            }

            // everything on the canvas (dots, cards) lives inside this inset, clipped viewport, so nothing
            // can poke out past the panel's rounded corners and there's always a small gap at the border
            Item {
                id: viewport
                anchors.fill: parent
                anchors.margins: 10
                clip: true

            Canvas {
                id: dots
                readonly property real inset: 6
                anchors.fill: parent
                anchors.margins: inset
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    const g = 26 * root.zoom;
                    if (g < 6) return;
                    // the canvas is inset, so shift the grid to stay aligned with the items
                    const ox = (((root.panX - inset) % g) + g) % g, oy = (((root.panY - inset) % g) + g) % g;
                    ctx.fillStyle = root.cDot;
                    ctx.beginPath();
                    for (let x = ox; x < width; x += g)
                        for (let y = oy; y < height; y += g) {
                            ctx.moveTo(x + 1.3, y);
                            ctx.arc(x, y, 1.3, 0, Math.PI * 2);
                        }
                    ctx.fill();
                }
                Connections {
                    target: root
                    function onZoomChanged() { dots.requestPaint(); }
                    function onPanXChanged() { dots.requestPaint(); }
                    function onPanYChanged() { dots.requestPaint(); }
                    function onCDotChanged() { dots.requestPaint(); }
                }
            }

            // keyboard: arrows move the selection, Enter copies, F2 edits, just type to search
            Item {
                id: keys
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: {
                    if (root.confirmOpen) root.confirmOpen = false;
                    else if (root.settingsOpen) root.settingsOpen = false;
                    else if (root.query !== "") root.query = "";
                    else if (root.selectedId !== "") root.selectedId = "";
                    else root.hide();
                }
                Keys.onLeftPressed: root.navigate(-1, 0)
                Keys.onRightPressed: root.navigate(1, 0)
                Keys.onUpPressed: root.navigate(0, -1)
                Keys.onDownPressed: root.navigate(0, 1)
                Keys.onReturnPressed: if (root.selectedId !== "") root.copyClip(root.selectedId)
                Keys.onEnterPressed: if (root.selectedId !== "") root.copyClip(root.selectedId)
                Keys.onDeletePressed: if (root.selectedId !== "") root.deleteClip(root.selectedId)
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_F2 && root.selectedId !== "") {
                        const i = root.idxOf(root.selectedId);
                        if (i >= 0 && clips.get(i).kind !== "image" && clips.get(i).kind !== "color") root.editingId = root.selectedId;
                        e.accepted = true;
                    } else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_F) {
                        search.forceActiveFocus(); e.accepted = true;
                    } else if (e.text.length === 1 && e.text.charCodeAt(0) >= 32 && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
                        search.forceActiveFocus();
                        search.text = search.text + e.text;
                        e.accepted = true;
                    }
                }
            }

            // pan + zoom (under the items)
            MouseArea {
                id: panArea
                anchors.fill: parent
                property real sx; property real sy; property real ox; property real oy
                onPressed: m => {
                    root.selectedId = "";
                    root.settingsOpen = false;
                    keys.forceActiveFocus();
                    sx = m.x; sy = m.y; ox = root.panX; oy = root.panY;
                    root.busy = true;
                }
                onPositionChanged: m => {
                    if (!pressed) return;
                    root.panX = ox + (m.x - sx);
                    root.panY = oy + (m.y - sy);
                }
                onReleased: { root.busy = false; dirty.restart(); }
                onWheel: w => {
                    const k = Math.exp(w.angleDelta.y * 0.0015);
                    const nz = Math.min(2.5, Math.max(0.15, root.zoom * k));
                    const f = nz / root.zoom;
                    root.panX = w.x - (w.x - root.panX) * f;
                    root.panY = w.y - (w.y - root.panY) * f;
                    root.zoom = nz;
                    dirty.restart();
                }
            }

            // ============================================================ items
            Item {
                id: world
                x: root.panX
                y: root.panY
                scale: root.zoom
                transformOrigin: Item.TopLeft

                Repeater {
                    model: clips
                    delegate: Item {
                        id: card
                        required property int index
                        required property string cid
                        required property bool local
                        required property string kind
                        required property string preview
                        required property string body
                        required property string label
                        required property bool pinned
                        required property string imgSrc
                        required property bool thumbOk
                        required property bool ready
                        required property real px
                        required property real py
                        required property real pw
                        required property real ph
                        required property real ps
                        required property real pr
                        required property real pz

                        readonly property bool isImage: kind === "image"
                        readonly property bool isColor: kind === "color"
                        readonly property bool textual: !isImage && !isColor
                        readonly property bool sized: pw > 0
                        readonly property bool hovered: hoverZone.containsMouse
                        readonly property bool selected: root.selectedId === cid
                        readonly property bool editing: root.editingId === cid
                        readonly property bool matched: root.matchesItem({ body: body, preview: preview, kind: kind, label: label })
                        readonly property string content: body !== "" ? body : preview
                        readonly property bool open: hovered || selected || editing
                        // grow on hover so the card stays readable even when the canvas is zoomed far out
                        readonly property real hoverScale: Math.min(4, Math.max(1.08, 1.15 / root.zoom))
                        property real sc: 1   // latched while dragging/resizing so nothing jumps

                        // no hover-grow while typing (search or editing) and none while dragging/resizing
                        function refreshScale() {
                            if (root.busy || editing) return;
                            sc = (hovered && matched && root.editingId === "" && !search.activeFocus) ? hoverScale : 1;
                        }
                        onHoveredChanged: refreshScale()
                        onMatchedChanged: refreshScale()
                        Connections {
                            target: root
                            function onBusyChanged() { card.refreshScale(); }
                            function onZoomChanged() { card.refreshScale(); }
                            function onEditingIdChanged() { card.refreshScale(); }
                        }
                        Connections {
                            target: search
                            function onActiveFocusChanged() { card.refreshScale(); }
                        }

                        x: px
                        y: py
                        z: (hovered || selected || editing) ? 1000000 + pz : (pinned ? 100000 + pz : pz)
                        scale: sc
                        opacity: matched ? 1 : 0.13
                        transformOrigin: Item.Center
                        width: box.width
                        height: box.height
                        Behavior on x { enabled: card.ready && !root.busy; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: card.ready && !root.busy; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 160 } }

                        // measured collapsed size, used by the overlap solver and keyboard navigation
                        Timer {
                            id: sizeSync
                            interval: 140
                            onTriggered: if (card.index >= 0) {
                                clips.setProperty(card.index, "mw", box.width);
                                clips.setProperty(card.index, "mh", box.height);
                            }
                        }
                        Component.onCompleted: sizeSync.restart()

                        // resize
                        property real rx0; property real ry0; property real rw0; property real rh0; property real rps0
                        function beginResize() { rx0 = px; ry0 = py; rw0 = box.width; rh0 = box.height; rps0 = ps; }
                        function doResize(sx, sy, dxw, dyh) {
                            const s = sc;
                            const L0 = rx0 + rw0 * (1 - s) / 2, R0 = rx0 + rw0 * (1 + s) / 2;
                            const T0 = ry0 + rh0 * (1 - s) / 2, B0 = ry0 + rh0 * (1 + s) / 2;
                            if (textual) {
                                clips.setProperty(index, "pw", Math.max(90, rw0 + sx * dxw / s));
                                clips.setProperty(index, "ph", Math.max(46, rh0 + sy * dyh / s));
                            } else {
                                const k = Math.max(0.2, (rw0 * s + sx * dxw) / (rw0 * s));
                                clips.setProperty(index, "ps", Math.min(4, Math.max(0.25, rps0 * k)));
                            }
                            const w = box.width, h = box.height;
                            clips.setProperty(index, "px", sx > 0 ? L0 - w * (1 - s) / 2 : R0 - w * (1 + s) / 2);
                            clips.setProperty(index, "py", sy > 0 ? T0 - h * (1 - s) / 2 : B0 - h * (1 + s) / 2);
                        }

                        // hover is tracked over the card plus the strip above it where the buttons live,
                        // so moving onto a button never counts as leaving the card
                        MouseArea {
                            id: hoverZone
                            x: 0
                            y: card.open ? -30 : 0
                            width: box.width
                            height: box.height + (card.open ? 30 : 0)
                            enabled: card.matched
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                        }

                        Rectangle {
                            id: box
                            width: sized ? card.pw : col.implicitWidth + 28
                            height: sized ? card.ph : col.implicitHeight + 24
                            onWidthChanged: sizeSync.restart()
                            onHeightChanged: sizeSync.restart()
                            radius: 14
                            color: card.open ? root.cPanel : "transparent"
                            border.width: card.open ? 1 : 0
                            border.color: root.cRing
                            Behavior on color { ColorAnimation { duration: 140 } }

                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                enabled: card.matched
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor
                                property real sx; property real sy; property real ox; property real oy
                                onPressed: m => {
                                    root.selectedId = card.cid;
                                    if (!card.editing) keys.forceActiveFocus();
                                    clips.setProperty(card.index, "pz", ++root.zTop);
                                    const p = mapToItem(panelClip, m.x, m.y);
                                    sx = p.x; sy = p.y; ox = card.px; oy = card.py;
                                    root.busy = true;
                                }
                                onPositionChanged: m => {
                                    if (!pressed || card.editing) return;
                                    const p = mapToItem(panelClip, m.x, m.y);
                                    clips.setProperty(card.index, "px", ox + (p.x - sx) / root.zoom);
                                    clips.setProperty(card.index, "py", oy + (p.y - sy) / root.zoom);
                                }
                                onReleased: { root.busy = false; root.scheduleResolve(card.cid); dirty.restart(); }
                                onDoubleClicked: if (card.textual) root.editingId = card.cid
                            }

                            Column {
                                id: col
                                x: 14; y: 12
                                spacing: 5

                                Row {
                                    spacing: 6
                                    height: 14
                                    Rectangle {
                                        width: 6; height: 6; radius: 3
                                        color: card.pinned ? "#ffd479" : root.cAcc
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: (card.pinned ? "PINNED · " : (card.local ? "NOTE · " : "")) +
                                              (card.isImage ? ("IMAGE" + (card.label !== "" ? " · " + card.label : "")) : card.kind.toUpperCase())
                                        color: root.cMute
                                        font.pixelSize: 10
                                        font.letterSpacing: 1.2
                                    }
                                }

                                // image
                                Item {
                                    visible: card.isImage
                                    width: 170 * card.ps
                                    height: img.status === Image.Ready ? width * img.implicitHeight / img.implicitWidth : width * 0.66
                                    Image {
                                        id: img
                                        anchors.fill: parent
                                        visible: false
                                        asynchronous: true
                                        fillMode: Image.Stretch
                                        sourceSize.width: 800
                                        source: (card.isImage && card.thumbOk && card.imgSrc !== "") ? "file://" + card.imgSrc : ""
                                    }
                                    Rectangle { id: imgMask; anchors.fill: parent; radius: 10; visible: false; layer.enabled: true }
                                    MultiEffect { anchors.fill: parent; source: img; maskEnabled: true; maskSource: imgMask }
                                }

                                // colour swatch
                                Row {
                                    visible: card.isColor
                                    spacing: 10
                                    Rectangle {
                                        width: 44 * card.ps; height: width; radius: width / 2
                                        color: card.isColor ? card.content.trim() : "transparent"
                                        border.width: 2; border.color: "#30ffffff"
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: card.content.trim()
                                        color: root.cFg
                                        font.pixelSize: 14
                                    }
                                }

                                // text / code / link / markdown (and the editor)
                                Item {
                                    id: textBox
                                    visible: card.textual
                                    // the whole text is always shown; only the width is capped and it wraps
                                    readonly property real textW: Math.min(300, Math.max(90, probe.implicitWidth))
                                    width: card.sized ? card.pw - 28 : textW
                                    height: card.sized
                                        ? Math.max(18, card.ph - 24 - 19)
                                        : Math.max(20, card.editing ? editor.implicitHeight : txt.implicitHeight)
                                    clip: card.sized

                                    Text {
                                        id: txt
                                        visible: !card.editing
                                        width: parent.width
                                        text: card.content !== "" ? card.content : "Empty note"
                                        textFormat: card.kind === "md" ? Text.MarkdownText : Text.PlainText
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        color: card.content === "" ? root.cMute
                                             : card.kind === "link" ? root.cAcc
                                             : card.kind === "code" ? root.cCode : root.cFg
                                        font.family: card.kind === "code" ? "monospace" : Qt.application.font.family
                                        font.pixelSize: card.kind === "code" ? 12.5 : 14
                                        font.italic: card.content === ""
                                        linkColor: root.cAcc
                                        onLinkActivated: link => Qt.openUrlExternally(link)
                                    }
                                    TextEdit {
                                        id: editor
                                        visible: card.editing
                                        width: parent.width
                                        wrapMode: TextEdit.Wrap
                                        selectByMouse: true
                                        color: root.cFg
                                        selectionColor: root.cAcc
                                        font.family: card.kind === "code" ? "monospace" : Qt.application.font.family
                                        font.pixelSize: card.kind === "code" ? 12.5 : 14
                                        Connections {
                                            target: card
                                            function onEditingChanged() {
                                                if (card.editing) {
                                                    editor.text = card.content;
                                                    editor.forceActiveFocus();
                                                    editor.cursorPosition = editor.length;
                                                }
                                            }
                                        }
                                        onActiveFocusChanged: if (!activeFocus && card.editing) root.commitEdit(card.cid, text)
                                        Keys.onEscapePressed: root.commitEdit(card.cid, text)
                                    }
                                    Text {
                                        id: probe
                                        visible: false
                                        text: card.content.slice(0, 400)
                                        wrapMode: Text.NoWrap
                                        font.family: txt.font.family
                                        font.pixelSize: txt.font.pixelSize
                                    }
                                }
                            }

                        }

                        // actions: a small strip above the card, never on top of the text
                        Row {
                            id: tools
                            property bool shown: (card.hovered || card.selected) && !card.editing && card.matched
                            visible: opacity > 0.01
                            opacity: shown ? 1 : 0
                            anchors { right: box.right; bottom: box.top; bottomMargin: 5 }
                            spacing: 3
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                            Pill { text: "Copy"; pillHeight: 20; fontSize: 10; hoverFx: false; pal: root.pal; onClicked: root.copyClip(card.cid) }
                            Pill { text: card.pinned ? "Unpin" : "Pin"; pillHeight: 20; fontSize: 10; hoverFx: false; active: card.pinned; pal: root.pal; onClicked: root.togglePin(card.cid) }
                            Pill { text: "✕"; pillHeight: 20; fontSize: 9; hoverFx: false; danger: true; pal: root.pal; implicitWidth: 22; onClicked: root.deleteClip(card.cid) }
                        }

                        // selection frame
                        Rectangle {
                            anchors.fill: box
                            anchors.margins: -2
                            radius: 16
                            color: "transparent"
                            border.width: 1.5
                            border.color: root.cAcc
                            visible: card.selected
                        }

                        // corner handles
                        Repeater {
                            model: [[-1, -1], [1, -1], [-1, 1], [1, 1]]
                            delegate: Rectangle {
                                id: handle
                                required property var modelData
                                readonly property int hx: modelData[0]
                                readonly property int hy: modelData[1]
                                visible: card.selected && !card.editing
                                width: 11; height: 11; radius: 3
                                color: hma.containsMouse ? root.cAcc : "white"
                                border.width: 1.5
                                border.color: root.cAcc
                                x: hx < 0 ? -7 : box.width - 4
                                y: hy < 0 ? -7 : box.height - 4
                                MouseArea {
                                    id: hma
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    hoverEnabled: true
                                    cursorShape: handle.hx * handle.hy > 0 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                                    property real sx; property real sy
                                    onPressed: m => {
                                        const p = mapToItem(panelClip, m.x, m.y);
                                        sx = p.x; sy = p.y;
                                        root.busy = true;
                                        card.beginResize();
                                    }
                                    onPositionChanged: m => {
                                        if (!pressed) return;
                                        const p = mapToItem(panelClip, m.x, m.y);
                                        card.doResize(handle.hx, handle.hy, (p.x - sx) / root.zoom, (p.y - sy) / root.zoom);
                                    }
                                    onReleased: { root.busy = false; root.scheduleResolve(card.cid); dirty.restart(); }
                                }
                            }
                        }
                    }
                }
            }

            }   // end viewport

            // ============================================================ chrome
            // grip
            Rectangle {
                id: grip
                x: 14; y: 11
                width: 54; height: 26; radius: 13
                color: gripArea.pressed ? root.cAcc : root.cRing
                Text { anchors.centerIn: parent; text: "⠿⠿⠿"; color: gripArea.pressed ? "#16161a" : root.cMute; font.pixelSize: 12 }
                MouseArea {
                    id: gripArea
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real sx; property real sy
                    function scr(m) {
                        const p = mapToItem(win.contentItem, m.x, m.y);
                        return Qt.point(p.x + (root.scrW - win.width), p.y);
                    }
                    onPressed: m => {
                        const p = scr(m); sx = p.x; sy = p.y;
                        root.liveW = root.panelW; root.liveH = root.panelH;
                        root.dragging = true;
                    }
                    onPositionChanged: m => {
                        if (!pressed) return;
                        const p = scr(m);
                        root.dragMove(p.x - sx, p.y - sy);
                    }
                    onReleased: m => {
                        const p = scr(m);
                        root.dragEnd(p.x - sx, p.y - sy, p.x, p.y);
                        root.dragging = false;
                    }
                }
            }

            // search
            Rectangle {
                id: searchBox
                x: 84; y: 11
                width: Math.max(120, Math.min(340, panelClip.width - 430))
                height: 26; radius: 13
                color: search.activeFocus ? Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.14) : root.cRing
                border.width: search.activeFocus ? 1 : 0
                border.color: root.cAcc
                Text {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    visible: search.text === ""
                    text: "Search…"
                    color: root.cMute
                    font.pixelSize: 12
                }
                TextInput {
                    id: search
                    anchors { fill: parent; leftMargin: 12; rightMargin: 28 }
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.cFg
                    selectionColor: root.cAcc
                    font.pixelSize: 12
                    clip: true
                    selectByMouse: true
                    onTextChanged: root.query = text
                    onAccepted: {
                        for (let i = 0; i < clips.count; i++) {
                            if (root.matchesItem(clips.get(i))) { root.selectedId = clips.get(i).cid; root.ensureVisible(i); break; }
                        }
                        keys.forceActiveFocus();
                    }
                    Keys.onEscapePressed: { text = ""; keys.forceActiveFocus(); }
                    Connections {
                        target: root
                        function onQueryChanged() { if (root.query === "" && search.text !== "") search.text = ""; }
                    }
                }
                Text {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    visible: search.text !== ""
                    text: "✕"
                    color: root.cMute
                    font.pixelSize: 11
                    MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: { search.text = ""; keys.forceActiveFocus(); } }
                }
            }

            // title + toolbar
            Text {
                id: titleText
                anchors { top: parent.top; right: parent.right; topMargin: 16; rightMargin: 26 }
                text: "CLIPBOARD"
                color: root.cFg
                opacity: 0.75
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.letterSpacing: 1.8
            }
            Row {
                anchors { top: parent.top; right: titleText.left; topMargin: 11; rightMargin: 16 }
                spacing: 6
                Pill { text: "+ Note"; pal: root.pal; onClicked: root.addNote() }
                Pill { text: "⚙"; pal: root.pal; active: root.settingsOpen; implicitWidth: 30; fontSize: 13; onClicked: root.settingsOpen = !root.settingsOpen }
                Pill { text: "✕"; pal: root.pal; danger: true; implicitWidth: 30; onClicked: root.hide() }
            }

            Pill {
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 14 }
                text: "RESET VIEW"
                fontSize: 10
                pal: root.pal
                onClicked: { root.fit(); dirty.restart(); }
            }

            // settings popover
            Rectangle {
                visible: root.settingsOpen
                anchors { top: parent.top; right: parent.right; topMargin: 46; rightMargin: 20 }
                width: 270
                height: setCol.implicitHeight + 24
                radius: 16
                color: root.cPanel
                border.width: 1
                border.color: root.cRing
                MouseArea { anchors.fill: parent }   // swallow clicks
                Column {
                    id: setCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 8
                    Text { text: "SETTINGS"; color: root.cMute; font.pixelSize: 10; font.letterSpacing: 1.4 }
                    Pill {
                        width: parent.width
                        text: "Wallpaper colours: " + (root.useWallpaper ? "On" : "Off") + (root.useWallpaper && root.wal === null ? "  (no colours file)" : "")
                        active: root.useWallpaper; pal: root.pal
                        onClicked: { root.useWallpaper = !root.useWallpaper; dirty.restart(); }
                    }
                    Pill {
                        width: parent.width
                        text: "Avoid overlap: " + (root.avoidOverlap ? "On" : "Off")
                        active: root.avoidOverlap; pal: root.pal
                        onClicked: { root.avoidOverlap = !root.avoidOverlap; if (root.avoidOverlap) root.resolve(""); dirty.restart(); }
                    }
                    Pill {
                        width: parent.width
                        text: "Paste after copy: " + (root.autoPaste ? "On" : "Off")
                        active: root.autoPaste; pal: root.pal
                        onClicked: { root.autoPaste = !root.autoPaste; dirty.restart(); }
                    }
                    Pill {
                        width: parent.width
                        text: "Tidy up now"
                        pal: root.pal
                        onClicked: { root.resolve(""); root.settingsOpen = false; }
                    }
                    Rectangle { width: parent.width; height: 1; color: root.cRing }
                    Pill {
                        width: parent.width
                        text: "Wipe everything…"
                        danger: true; pal: root.pal
                        onClicked: { root.settingsOpen = false; root.confirmOpen = true; }
                    }
                }
            }

            // toast
            Rectangle {
                visible: root.toastText !== ""
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 48 }
                width: toastLabel.implicitWidth + 28; height: 28; radius: 14
                color: root.cFg
                Text { id: toastLabel; anchors.centerIn: parent; text: root.toastText; color: "#16161a"; font.pixelSize: 12; font.weight: Font.DemiBold }
            }

            // confirm wipe
            Rectangle {
                id: confirmLayer
                visible: root.confirmOpen
                anchors.fill: parent
                color: "#99000000"
                z: 10
                MouseArea { anchors.fill: parent; hoverEnabled: true }   // modal: blocks everything underneath
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(360, parent.width - 40)
                    height: confirmCol.implicitHeight + 36
                    radius: 18
                    color: root.cPanel
                    border.width: 1
                    border.color: root.cRing
                    Column {
                        id: confirmCol
                        x: 18; y: 18
                        width: parent.width - 36
                        spacing: 12
                        Text {
                            text: "Wipe everything?"
                            color: root.cFg
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            color: root.cMute
                            font.pixelSize: 12
                            text: "This deletes your entire clipboard history, every pinned item and note, and all saved layouts. It can't be undone."
                        }
                        Row {
                            spacing: 8
                            anchors.right: parent.right
                            Pill { text: "Cancel"; pal: root.pal; onClicked: root.confirmOpen = false }
                            Pill { text: "Confirm wipe"; danger: true; pal: root.pal; onClicked: root.wipeAll() }
                        }
                    }
                }
            }
        }
    }
}
