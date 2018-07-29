.PHONY:	me default

default:
	@echo "$(MAKE) me ... install Arch Linux on your computer."
	@echo "            this command should be run from the Arch Linux bootable media."

me:
	./setup-scripts/stage01.sh
