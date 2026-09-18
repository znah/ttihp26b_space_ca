.PHONY: all build visualize visualize-klayout sim

CONFIGS = src/config.json flow/config.json

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
build: $(CONFIGS) src/project.v src/hvsync_generator.v
	@echo "Running implementation flow..."
	$(RUN_CMD) "python3 -m librelane --pdk ihp-sg13g2 --run-tag main --overwrite $(CONFIGS)"

# 3. View layout in OpenROAD GUI
visualize:
	$(RUN_CMD) "python3 -m librelane --pdk ihp-sg13g2 --flow openinopenroad --run-tag main $(CONFIGS)"

# 4. View layout in KLayout
visualize-klayout:
	$(RUN_CMD) "python3 -m librelane --pdk ihp-sg13g2 --flow openinklayout --run-tag main $(CONFIGS)"
