.PHONY: all build visualize sim

CONFIG = flow/config.json

ifneq ($(MAKECMDGOALS),sim)
ifndef LIBRELANE_ROOT
  $(error LIBRELANE_ROOT is not defined. Please set it to your librelane directory)
endif
endif

RUN_CMD = nix-shell $(LIBRELANE_ROOT) --run
SIM_SRC = sim/main.cpp src/project.v src/hvsync_generator.v

all: build

# 1. Simulation (Verilator)
sim: $(SIM_SRC)
	@echo "Running simulation..."
	verilator --cc --exe --build -j 0 -O3 $(SIM_SRC) -LDFLAGS "-framework Cocoa" \
		-o demo -DSIM && obj_dir/demo

# 2. Run the LibreLane flow
build: $(CONFIG) src/project.v src/hvsync_generator.v
	@echo "Running implementation flow..."
	$(RUN_CMD) "python3 -m librelane --pdk ihp-sg13g2 --run-tag main --overwrite $(CONFIG)"
