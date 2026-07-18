SDK ?= $(PLAYDATE_SDK_PATH)
PDC ?= $(SDK)/bin/pdc
SIM ?= $(SDK)/bin/PlaydateSimulator

GAME = PlayAgent.pdx

.PHONY: build
build:
	"$(PDC)" source $(GAME)

.PHONY: run
run: build
	"$(SIM)" $(GAME)

.PHONY: clean
clean:
	rm -rf $(GAME)

# Serve your config to the Playdate (Settings -> Import config (Wi-Fi)).
# First run creates tools/playagent-config.json to edit.
# Extra flags: make provision ARGS="--forever --password 123456"
.PHONY: provision
provision:
	python3 tools/provision.py $(ARGS)

# Regenerate launcher art (icon, card, launch image)
.PHONY: assets
assets:
	python3 tools/gen_assets.py

.PHONY: fonts
fonts:
	python3 tools/gen_fonts.py

# WSL only: forward Windows :$(PORT) to WSL so the Playdate can reach
# servers running here (provisioning, opencode serve, ...). Asks for UAC.
# Re-run after a Windows reboot (the WSL IP changes).
PORT ?= 9393
.PHONY: wsl-forward
wsl-forward:
	bash tools/wsl_portproxy.sh $(PORT)

.PHONY: wsl-unforward
wsl-unforward:
	bash tools/wsl_portproxy.sh $(PORT) remove

.PHONY: wsl-status
wsl-status:
	bash tools/wsl_portproxy.sh status
