.PHONY:	me default sync

default:
	@echo "$(MAKE) me ... install Arch Linux on your computer."
	@echo "            this command should be run from the Arch Linux bootable media."
	@echo "$(MAKE) sync ... update packages on the system."

me:
	./setup-scripts/stage01.sh

sync:
	ansible-playbook -i <(echo "localhost") -K exec.yml
