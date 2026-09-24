# Constants
CLAB = clab-frr-sr-mpls
LOG_FILE = setup.log

# Functions
define log
    echo "[$(shell date '+%Y-%m-%d %H:%M:%S')] $1" >> $(LOG_FILE)
endef

define exec_vtysh
	docker exec -it clab-frr-sr-mpls-$1 vtysh
endef

define exec_shell
	docker exec -it clab-frr-sr-mpls-$1 bash
endef

# ContainerLAB life cycle
.PHONY: initialize-log
initialize-log:
	@echo -n "" > $(LOG_FILE)

.PHONY: lab
lab: initialize-log
	@$(call log,Loading MPLS kernel modules...)
	@sudo modprobe mpls_router mpls_iptunnel mpls_gso >> $(LOG_FILE) 2>&1
	@$(call log,Deploying ContainerLAB topology...)
	@sudo clab deploy --topo lab.yml >> $(LOG_FILE) 2>&1
	@sleep 5
	@$(call log,ContainerLAB topology successfully deployed.)

.PHONY: configure
configure: lab
	@$(call log,Starting configuration...)
	@echo "Configuration complete. Check 'setup.log' for detailed output."

all: configure

.PHONY: clean
clean: initialize-log
	@$(call log,Cleaning up...)
	@sudo clab destroy --cleanup --topo lab.yml >> $(LOG_FILE) 2>&1
	@$(call log,Cleaning complete.)
	@echo "Cleaning complete. Check 'setup.log' for detailed output."

# Interacting with ContainerLAB components
.PHONY: inspect
inspect:
	@sudo clab inspect --topo lab.yml

.PHONY: p1 p2 p3 p4 p5 p6 pe11 pe12 rr14 bdr13
p1 p2 p3 p4 p5 p6 pe11 pe12 rr14 bdr13:
	$(call exec_vtysh,$(subst -,_,$@))

.PHONY: c1 c2 c3 pola
c1 c2 c3 pola:
	$(call exec_shell,$(subst -,_,$@))
