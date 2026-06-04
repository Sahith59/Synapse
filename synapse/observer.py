#!/usr/bin/env python3
"""
synapse/observer.py
─────────────────
Tiered text extraction from the active macOS window.

Tier 1 — Native scripting bridge: Safari, Chrome, Notes, Mail, Pages, Word
Tier 2 — AX deep extraction: Terminal, Xcode, Cursor/Electron, generic apps
Tier 3 — OCR screenshot fallback for anything that AX can't reach
"""

import hashlib
import json
import re
import socket
import subprocess
import time

OCR_AVAILABLE = False  # OCR disabled in daemon thread — fork-unsafe with FAISS/CoreML loaded

SOCKET_PATH    = "/tmp/synapse.sock"
POLL_INTERVAL  = 3.0   # seconds between polls
MIN_CHARS      = 30    # minimum content length worth storing
MAX_CHARS      = 5000  # cap per snapshot

# Apps we never want to capture (system / self)
SKIP_APPS = {
    "SynapseDemo", "loginwindow", "Dock", "Finder",
    "SystemUIServer", "ControlCenter", "NotificationCenter",
    "Spotlight", "Alfred", "Raycast", "com.apple.appkit.xpc.openAndSavePanelService",
}

# ── AppleScript ───────────────────────────────────────────────────────────────
# Returns "source | content" where source is the human-readable app name.
# Process name is embedded as first token before " | " so Python can route OCR.
APPLESCRIPT = r"""
global frontApp, frontAppName, displayName

tell application "System Events"
    set frontApp to first application process whose frontmost is true
    set frontAppName to name of frontApp

    -- Hard skip: system / self apps return empty so Python ignores them
    if frontAppName is in {"SynapseDemo", "loginwindow", "Dock", "Finder", ¬
        "SystemUIServer", "ControlCenter", "NotificationCenter", ¬
        "Spotlight", "Alfred", "Raycast"} then
        return ""
    end if

    -- Resolve human-readable name for Electron-shell apps
    set displayName to frontAppName
    if frontAppName is "Electron" then
        try
            set winTitle to value of attribute "AXTitle" of ¬
                (first window whose value of attribute "AXMain" is true) of frontApp
            -- Window titles like "file.swift — Cursor" or "project - Visual Studio Code"
            if winTitle contains " — " then
                set AppleScript's text item delimiters to " — "
                set displayName to last text item of winTitle
                set AppleScript's text item delimiters to ""
            else if winTitle contains " - " then
                set AppleScript's text item delimiters to " - "
                set displayName to last text item of winTitle
                set AppleScript's text item delimiters to ""
            else
                set displayName to winTitle
            end if
        on error
            set displayName to "Electron"
        end try
    end if
end tell

-- ── Safari ────────────────────────────────────────────────────────────────────
if frontAppName is "Safari" then
    tell application "Safari"
        try
            if (count of documents) > 0 then
                set pg to front document
                return "safari | " & name of pg & return & "URL: " & URL of pg & return & (text of pg)
            end if
        on error
            return "safari | (Enable Allow JavaScript from Apple Events in Develop menu)"
        end try
    end tell
    return "safari | (No document)"

-- ── Google Chrome ─────────────────────────────────────────────────────────────
else if frontAppName is "Google Chrome" then
    tell application "Google Chrome"
        try
            if (count of windows) > 0 then
                set t to active tab of front window
                set pgText to execute t javascript "document.body.innerText"
                return "chrome | " & title of t & return & "URL: " & URL of t & return & pgText
            end if
        on error
            return "chrome | (Enable Allow JavaScript from Apple Events in View > Developer)"
        end try
    end tell
    return "chrome | (No window)"

-- ── Notes ─────────────────────────────────────────────────────────────────────
else if frontAppName is "Notes" then
    tell application "Notes"
        try
            if (count of notes) > 0 then
                set n to note 1 of folder "Notes" of default account
                set rawBody to body of n
                set cleanBody to do shell script "echo " & quoted form of rawBody & ¬
                    " | sed -e 's/<[^>]*>//g' -e '/^[[:space:]]*$/d'"
                return "notes | " & name of n & return & cleanBody
            end if
        on error
            return "notes | (Could not read note)"
        end try
    end tell
    return "notes | (No notes found)"

-- ── Mail ──────────────────────────────────────────────────────────────────────
else if frontAppName is "Mail" then
    tell application "Mail"
        try
            if (count of message viewers) > 0 then
                set msgs to selected messages of front message viewer
                if (count of msgs) > 0 then
                    set m to item 1 of msgs
                    return "mail | From: " & sender of m & return & ¬
                        "Subject: " & subject of m & return & (content of m)
                end if
            end if
        on error
        end try
    end tell
    return "mail | (No message selected)"

-- ── Pages ─────────────────────────────────────────────────────────────────────
else if frontAppName is "Pages" then
    tell application "Pages"
        try
            if (count of documents) > 0 then
                return "pages | " & name of front document & return & body text of front document
            end if
        on error
        end try
    end tell
    return "pages | (No document)"

-- ── Microsoft Word ────────────────────────────────────────────────────────────
else if frontAppName is "Microsoft Word" then
    tell application "Microsoft Word"
        try
            if (count of documents) > 0 then
                return "word | " & name of active document & return & ¬
                    content of text object of active document
            end if
        on error
        end try
    end tell
    return "word | (No document)"

-- ── Terminal.app ──────────────────────────────────────────────────────────────
else if frontAppName is "Terminal" then
    tell application "System Events"
        tell process "Terminal"
            try
                set mainWin to first window whose value of attribute "AXMain" is true
                set winTitle to value of attribute "AXTitle" of mainWin
                set termText to ""
                try
                    set sa to first scroll area of mainWin
                    set termText to value of first text area of sa
                on error
                    try
                        set termText to value of first text area of mainWin
                    on error
                    end try
                end try
                return "terminal | " & winTitle & return & termText
            on error
                return "terminal | (Could not read terminal buffer)"
            end try
        end tell
    end tell

-- ── iTerm2 ────────────────────────────────────────────────────────────────────
else if frontAppName is "iTerm2" then
    tell application "System Events"
        tell process "iTerm2"
            try
                set mainWin to first window whose value of attribute "AXMain" is true
                set winTitle to value of attribute "AXTitle" of mainWin
                set allText to ""
                set tas to text areas of mainWin
                repeat with ta in tas
                    try
                        set v to value of ta
                        if v is not missing value then set allText to allText & v & return
                    on error
                    end try
                end repeat
                return "terminal | " & winTitle & return & allText
            on error
                return "terminal | (Could not read iTerm2)"
            end try
        end tell
    end tell

-- ── Xcode ─────────────────────────────────────────────────────────────────────
else if frontAppName is "Xcode" then
    tell application "System Events"
        tell process "Xcode"
            try
                set mainWin to first window whose value of attribute "AXMain" is true
                set winTitle to value of attribute "AXTitle" of mainWin
                set editorText to ""
                -- Focused element is the open source file
                try
                    set focEl to value of attribute "AXFocusedUIElement" of mainWin
                    set focVal to value of focEl
                    if focVal is not missing value and length of focVal > 20 then
                        set editorText to focVal
                    end if
                on error
                end try
                -- If focused element didn't yield text, try text areas
                if editorText is "" then
                    try
                        set tas to text areas of mainWin
                        repeat with ta in tas
                            try
                                set v to value of ta
                                if v is not missing value and length of v > 20 then
                                    set editorText to editorText & v & return
                                end if
                            on error
                            end try
                        end repeat
                    on error
                    end try
                end if
                return "xcode | " & winTitle & return & editorText
            on error
                return "xcode | (Could not read Xcode editor)"
            end try
        end tell
    end tell

-- ── Cursor / VS Code / other Electron apps ────────────────────────────────────
else if frontAppName is "Electron" then
    tell application "System Events"
        tell process "Electron"
            try
                set mainWin to first window whose value of attribute "AXMain" is true
                set winTitle to value of attribute "AXTitle" of mainWin
                set collectedText to winTitle & return
                -- Try focused element first (the active editor pane)
                try
                    set focEl to value of attribute "AXFocusedUIElement" of mainWin
                    set focVal to value of focEl
                    if focVal is not missing value and length of focVal > 20 then
                        set collectedText to collectedText & return & focVal & return
                    end if
                on error
                end try
                -- Collect visible text areas (editor panels, terminal panels)
                try
                    set tas to text areas of mainWin
                    repeat with ta in tas
                        try
                            set v to value of ta
                            if v is not missing value and length of v > 20 then
                                set collectedText to collectedText & v & return
                            end if
                        on error
                        end try
                    end repeat
                on error
                end try
                return displayName & " | " & collectedText
            on error
                return displayName & " | (Could not read)"
            end try
        end tell
    end tell

-- ── Generic fallback: AX tree (focused element + static texts) ────────────────
else
    tell application "System Events"
        tell process frontAppName
            try
                set mainWin to first window whose value of attribute "AXMain" is true
                set winTitle to value of attribute "AXTitle" of mainWin
                set collectedText to winTitle & return

                -- Focused element: what the user is actually looking at / typing in
                try
                    set focEl to value of attribute "AXFocusedUIElement" of mainWin
                    set focVal to value of focEl
                    if focVal is not missing value and length of focVal > 5 then
                        set collectedText to collectedText & return & "[Active]" & return & focVal & return
                    end if
                on error
                end try

                -- Text areas (document bodies, editors)
                try
                    set tas to text areas of mainWin
                    set taCount to 0
                    repeat with ta in tas
                        if taCount > 5 then exit repeat
                        try
                            set v to value of ta
                            if v is not missing value and length of v > 5 then
                                set collectedText to collectedText & v & return
                                set taCount to taCount + 1
                            end if
                        on error
                        end try
                    end repeat
                on error
                end try

                -- Static text elements (labels, content)
                try
                    set staticItems to every static text of mainWin
                    set staticCount to 0
                    repeat with staticItem in staticItems
                        if staticCount > 80 then exit repeat
                        try
                            set v to value of staticItem
                            if v is not missing value and length of v > 3 then
                                set collectedText to collectedText & v & return
                                set staticCount to staticCount + 1
                            end if
                        on error
                        end try
                    end repeat
                on error
                end try

                return displayName & " | " & collectedText
            on error
                return frontAppName & " | "
            end try
        end tell
    end tell
end if
"""


def _clean_text(raw: str) -> str:
    """Normalise whitespace, deduplicate adjacent lines, drop junk short lines."""
    lines = raw.splitlines()
    seen: set[str] = set()
    cleaned: list[str] = []
    for line in lines:
        line = line.strip()
        if len(line) < 3:
            continue
        # Skip lines that are clearly UI chrome (single words / numbers)
        if len(line) <= 6 and not any(c.isalpha() for c in line):
            continue
        if line in seen:
            continue
        seen.add(line)
        cleaned.append(line)
    return "\n".join(cleaned)


class Observer:
    _CACHE_SIZE = 50  # unique snapshots to remember for dedup

    def __init__(self):
        self._seen_hashes: list[str] = []

    def _content_hash(self, text: str) -> str:
        normalised = text.strip().lower()[:1000]
        return hashlib.md5(normalised.encode()).hexdigest()[:16]

    def _is_duplicate(self, text: str) -> bool:
        return self._content_hash(text) in self._seen_hashes

    def _mark_seen(self, text: str):
        h = self._content_hash(text)
        if h in self._seen_hashes:
            return
        self._seen_hashes.append(h)
        if len(self._seen_hashes) > self._CACHE_SIZE:
            self._seen_hashes.pop(0)

    def run_applescript(self) -> str:
        try:
            result = subprocess.run(
                ["osascript", "-e", APPLESCRIPT],
                capture_output=True,
                text=True,
                timeout=8,  # hard kill if AX walk hangs
            )
            return result.stdout.strip()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return ""

    def store_in_synapse(self, text: str, source: str) -> bool:
        """Returns True if stored successfully, False otherwise."""
        payload = {"action": "store", "text": text, "source": source}
        fd = None
        try:
            fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            fd.settimeout(3.0)
            fd.connect(SOCKET_PATH)
            fd.sendall(json.dumps(payload).encode() + b"\n")
            buf = b""
            while b"\n" not in buf:
                chunk = fd.recv(4096)
                if not chunk:
                    break
                buf += chunk
            resp = json.loads(buf.strip())
            if resp.get("ok"):
                print(f"[Observer] {source} -> #{resp.get('id')} ({len(text)} chars)", flush=True)
                return True
            else:
                print(f"[Observer] Store failed: {resp.get('error')}", flush=True)
                return False
        except Exception as e:
            print(f"[Observer] Socket error: {e}", flush=True)
            return False
        finally:
            if fd:
                fd.close()

    # Apps where AppleScript returns deep native content (no OCR needed)
    _NATIVE_DEEP = {"safari", "chrome", "notes", "mail", "pages", "word",
                    "terminal", "xcode"}

    # Electron-shell apps: their OS window owner is "Electron"
    _ELECTRON_APPS = {
        "cursor", "visual studio code", "slack", "discord",
        "notion", "figma", "linear", "arc",
    }

    def _ocr_subprocess(self, proc_name: str) -> str:
        """Run OCR in a child process — Vision Framework is not thread-safe."""
        import sys
        import os
        python = sys.executable
        ocr_script = os.path.join(os.path.dirname(__file__), "ocr.py")
        proj_root = os.path.dirname(os.path.dirname(__file__))
        try:
            r = subprocess.run(
                [python, ocr_script, proc_name],
                capture_output=True, text=True, timeout=12,
                cwd=proj_root,
            )
            return r.stdout.strip()
        except Exception:
            return ""

    def _wait_for_socket(self, timeout: float = 60.0):
        """Block until the Synapse socket exists (server has started)."""
        import os
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(SOCKET_PATH):
                return True
            time.sleep(1.0)
        print("[Observer] WARNING: socket never appeared, proceeding anyway", flush=True)
        return False

    def start(self):
        print("[Observer] Starting — tiered AX + OCR extraction", flush=True)

        # Wait for server socket before first poll — observer thread starts
        # before server.start() creates the socket.
        self._wait_for_socket()
        print("[Observer] Socket ready — beginning capture loop", flush=True)

        while True:
            raw = self.run_applescript()

            if not raw or " | " not in raw:
                time.sleep(POLL_INTERVAL)
                continue

            source, content = raw.split(" | ", 1)
            source = source.strip().lower()

            # OCR augmentation: spawn a child process so Vision Framework
            # doesn't corrupt the daemon (PyObjC/Vision is not thread-safe).
            if source not in self._NATIVE_DEEP:
                proc_name = "Electron" if source in self._ELECTRON_APPS else source.title()
                ocr_text = self._ocr_subprocess(proc_name)
                if not ocr_text or len(ocr_text) < 20:
                    ocr_text = self._ocr_subprocess("Electron")
                if ocr_text and len(ocr_text) > 20:
                    content = content + "\n\n" + ocr_text

            text = _clean_text(content)[:MAX_CHARS]

            if len(text) < MIN_CHARS or self._is_duplicate(text):
                time.sleep(POLL_INTERVAL)
                continue

            # Only mark seen if store succeeded — retry on socket errors.
            if self.store_in_synapse(text, source):
                self._mark_seen(text)

            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    Observer().start()
