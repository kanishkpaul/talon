# talon — build, test, sign, install.
#
#   make                 build release binaries
#   make test            run the test suite
#   make app             build the menu bar app (make app-demo: run it on synthetic data)
#   make agent           run talond as a per-user LaunchAgent (no admin; your processes only)
#   make build && sudo make install
#                        run talond as a root LaunchDaemon (every process; kernel ceilings on running apps)
#   make logs            follow talon's log

SHELL     := /bin/bash
RELEASE   := .build/release
LABEL     := dev.kanishk.talond
AGENT     := $(LABEL).agent
UID_NOW   := $(shell id -u)
AGENT_DIR := $(HOME)/Library/Application Support/Talon/bin
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT).plist
HELPER    := /Library/PrivilegedHelperTools/$(LABEL)
DAEMON_PLIST := /Library/LaunchDaemons/$(LABEL).plist
PREFIX    ?= /usr/local

.PHONY: all build test sign app app-demo snapshots agent unagent install uninstall logs spikes clean

all: build

build:
	swift build -c release
	@$(MAKE) --no-print-directory sign

# Ad-hoc signatures with stable identifiers and the hardened runtime. Phase 0 showed ad-hoc is
# enough for a LaunchDaemon; the helper's safety holds without a Team ID (uid checks, typed verbs).
sign:
	codesign -s - -f --options runtime -i $(LABEL) $(RELEASE)/talond
	codesign -s - -f --options runtime -i dev.kanishk.talon $(RELEASE)/talon

test:
	swift test

APP := .build/app/Build/Products/Release/Talon.app

# The menu bar app (XcodeGen + xcodebuild). Links only TalonModel + TalonIPC.
app:
	cd App && xcodegen generate --quiet
	xcodebuild -project App/Talon.xcodeproj -scheme TalonApp -configuration Release \
		-derivedDataPath .build/app -quiet build
	@echo "built $(APP) · open it, or: make app-demo"

app-demo: app
	open -n $(APP) --args --demo --open

# Render the panel, Overview and Processes (light + dark) to .build/snapshots without touching the
# screen; the panel shots are copied into docs/screenshots for the README.
snapshots: app
	rm -rf .build/snapshots
	$(APP)/Contents/MacOS/Talon --demo --snapshot .build/snapshots
	mkdir -p docs/screenshots && cp .build/snapshots/panel-*.png docs/screenshots/

agent: build
	@mkdir -p "$(AGENT_DIR)" "$(HOME)/Library/LaunchAgents"
	install -m 755 $(RELEASE)/talond "$(AGENT_DIR)/talond"
	sed "s|__BIN__|$(AGENT_DIR)/talond|" launchd/$(AGENT).plist > "$(AGENT_PLIST)"
	-launchctl bootout gui/$(UID_NOW)/$(AGENT) 2>/dev/null
	launchctl bootstrap gui/$(UID_NOW) "$(AGENT_PLIST)"
	@echo "talond agent running · try: $(RELEASE)/talon daemon"

unagent:
	-launchctl bootout gui/$(UID_NOW)/$(AGENT) 2>/dev/null
	rm -f "$(AGENT_PLIST)" "$(AGENT_DIR)/talond"
	@echo "talond agent removed (history kept in ~/Library/Application Support/Talon)"

# Needs prebuilt binaries: `make build && sudo make install` (building as root would leave
# root-owned files in .build).
install:
	@[ "$$EUID" -eq 0 ] || { echo "run: make build && sudo make install"; exit 1; }
	@[ -n "$$SUDO_UID" ] || { echo "run via sudo from your own account"; exit 1; }
	@[ -x $(RELEASE)/talond ] || { echo "build first: make build"; exit 1; }
	-launchctl bootout system/$(LABEL) 2>/dev/null
	mkdir -p /Library/PrivilegedHelperTools
	install -m 755 -o root -g wheel $(RELEASE)/talond $(HELPER)
	sed "s|__UID__|$$SUDO_UID|" launchd/$(LABEL).plist > $(DAEMON_PLIST)
	chown root:wheel $(DAEMON_PLIST); chmod 644 $(DAEMON_PLIST)
	launchctl bootstrap system $(DAEMON_PLIST)
	launchctl kickstart -k system/$(LABEL)
	install -d $(PREFIX)/bin
	install -m 755 $(RELEASE)/talon $(PREFIX)/bin/talon
	@echo "talond installed as root daemon for uid $$SUDO_UID · try: talon daemon"

uninstall:
	@[ "$$EUID" -eq 0 ] || { echo "run: sudo make uninstall"; exit 1; }
	-launchctl bootout system/$(LABEL) 2>/dev/null
	rm -f $(DAEMON_PLIST) $(HELPER) $(PREFIX)/bin/talon /var/log/$(LABEL).log
	@echo "talond removed (history kept in /Library/Application Support/Talon)"

logs:
	log stream --style compact --level info --predicate 'subsystem == "dev.kanishk.talon"'

spikes:
	cd spikes && ./build.sh

clean:
	swift package clean
