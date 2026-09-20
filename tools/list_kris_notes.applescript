tell application "Notes"
    set outputItems to {}
    repeat with accountItem in accounts
        try
            set targetFolder to folder "Kris 健身" of accountItem
            repeat with noteItem in notes of targetFolder
                set end of outputItems to ((name of noteItem) as text) & tab & ((id of noteItem) as text)
            end repeat
        end try
    end repeat
end tell
set AppleScript's text item delimiters to linefeed
return outputItems as text
