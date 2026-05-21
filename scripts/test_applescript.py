import subprocess

def run_applescript(script):
    try:
        result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        return f"Error: {e.stderr.strip()}"

script = """
global frontApp, frontAppName, windowText

tell application "System Events"
    set frontApp to first application process whose frontmost is true
    set frontAppName to name of frontApp
    
    -- Specific handling for browsers to get URL and page title
    if frontAppName is "Safari" then
        tell application "Safari"
            set docText to text of front document
            return "Safari | " & docText
        end tell
    else if frontAppName is "Google Chrome" then
        tell application "Google Chrome"
            set docText to execute front window's active tab javascript "document.body.innerText"
            return "Chrome | " & docText
        end tell
    else if frontAppName is "Notes" then
        tell application "Notes"
            set docText to body of front note
            return "Notes | " & docText
        end tell
    else
        -- Fallback to AXDocument or AXTitle
        tell process frontAppName
            try
                set windowText to value of attribute "AXTitle" of (1st window whose value of attribute "AXMain" is true)
                return frontAppName & " | " & windowText
            on error
                return frontAppName & " | (No readable text)"
            end try
        end tell
    end if
end tell
"""

print(run_applescript(script))
