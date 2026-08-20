APP       := ClaudeCron
BUILD     := .build
DIST      := dist/$(APP).app
DEMO      := /tmp/claude-cron-demo
SHOTS     := docs/screenshots
GENERATED := Sources/ClaudeCron/RunnerScript.generated.swift

CORE_SRC := $(wildcard Sources/Core/*.swift)
APP_SRC  := $(wildcard Sources/ClaudeCron/*.swift) $(GENERATED)
TEST_SRC := Sources/CronTest/main.swift

SWIFTC := swiftc -O

.PHONY: all gen build test app install demo demo-stop screenshots clean

all: app

gen: $(GENERATED)

$(GENERATED): runner/runner.zsh packaging/gen_runner.py
	python3 packaging/gen_runner.py runner/runner.zsh $(GENERATED)

$(BUILD)/$(APP): $(CORE_SRC) $(APP_SRC)
	mkdir -p $(BUILD)
	$(SWIFTC) -parse-as-library $(CORE_SRC) $(sort $(APP_SRC)) -o $(BUILD)/$(APP)

build: gen $(BUILD)/$(APP)

test: gen
	mkdir -p $(BUILD)
	$(SWIFTC) $(CORE_SRC) $(TEST_SRC) -o $(BUILD)/crontest
	$(BUILD)/crontest

app: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources
	cp $(BUILD)/$(APP) $(DIST)/Contents/MacOS/$(APP)
	cp packaging/Info.plist $(DIST)/Contents/Info.plist
	codesign --force -s - $(DIST)
	@echo "Built $(DIST)"

install: app
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf ~/Applications/$(APP).app
	mkdir -p ~/Applications
	cp -R $(DIST) ~/Applications/$(APP).app
	@echo "Installed to ~/Applications/$(APP).app"

demo: app
	python3 packaging/demo_seed.py $(DEMO)
	@CLAUDE_CRON_CONFIG=$(DEMO)/config \
	 CLAUDE_CRON_LOGS=$(DEMO)/logs \
	 CLAUDE_CRON_LAUNCH_AGENTS=$(DEMO)/agents \
	 open -n $(DIST)
	@echo "Demo instance running against $(DEMO) (sandboxed: launchd untouched)."
	@echo "Stop it with: make demo-stop"

demo-stop:
	@for pid in $$(pgrep -x $(APP)); do \
	  if ps eww -o command= -p $$pid | grep -q CLAUDE_CRON_LAUNCH_AGENTS; then \
	    kill $$pid && echo "stopped demo instance $$pid"; \
	  fi; \
	done; true

# README pictures: seeded demo data, sandboxed instance, self-capture, quit.
screenshots: app
	python3 packaging/demo_seed.py $(DEMO)
	@CLAUDE_CRON_CONFIG=$(DEMO)/config \
	 CLAUDE_CRON_LOGS=$(DEMO)/logs \
	 CLAUDE_CRON_LAUNCH_AGENTS=$(DEMO)/agents \
	 CLAUDE_CRON_SCREENSHOTS=$(CURDIR)/$(SHOTS) \
	 $(DIST)/Contents/MacOS/$(APP) -AppleLanguages "(en)" -AppleLocale en_US
	@echo "Screenshots written to $(SHOTS)/"

clean:
	rm -rf $(BUILD) dist
