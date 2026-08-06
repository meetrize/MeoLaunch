on run argv
	set appPath to item 1 of argv
	set adminPass to item 2 of argv
	set appName to do shell script "basename " & quoted form of appPath & " .app"

	do shell script "open 'x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility'"
	delay 2.5

	tell application "System Events"
		tell process "System Settings"
			set frontmost to true
			repeat 20 times
				if exists window 1 then exit repeat
				delay 0.2
			end repeat
			if not (exists window 1) then error "System Settings window not found"

			-- Unlock (lock button label varies by macOS version)
			try
				set lockCandidates to every button of window 1 whose description contains "lock" or name contains "lock"
				repeat with lb in lockCandidates
					try
						click lb
						delay 0.4
						keystroke adminPass
						key code 36
						delay 1.0
						exit repeat
					end try
				end repeat
			end try

			-- Enable if already listed
			try
				repeat with cb in (every checkbox of window 1)
					try
						set cbName to name of cb
						if cbName contains appName then
							if value of cb is 0 then
								click cb
								return "enabled-existing"
							end if
							return "already-enabled"
						end if
					end try
				end repeat
			end try

			-- Add via + button
			set added to false
			repeat with b in (every button of window 1)
				try
					if name of b is "+" or description of b contains "add" then
						click b
						set added to true
						exit repeat
					end if
				end try
			end repeat
			if not added then
				try
					click button 1 of group 2 of scroll area 1 of group 1 of window 1
					set added to true
				end try
			end if
			if not added then error "Could not find + button in Accessibility settings"

			delay 1.2
		end tell

		-- File picker sheet (still under System Settings or separate open panel)
		keystroke "g" using {command down, shift down}
		delay 0.6
		keystroke appPath
		key code 36
		delay 0.8
		keystroke return
		delay 0.5
		try
			click button "Open" of window 1 of process "System Settings"
		on error
			try
				key code 36
			end try
		end try
		delay 0.8

		tell process "System Settings"
			try
				repeat with cb in (every checkbox of window 1)
					try
						if name of cb contains appName and value of cb is 0 then
							click cb
						end if
					end try
				end repeat
			end try
		end tell
	end tell

	return "added"
end run
