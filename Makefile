NAME := vitis_example

# Directory to place output products
BUILD := build

# Directory to place XSCT workspace products
WORKSPACE := $(BUILD)/xsct

# Software emulation (sw_emu), hardware emulation (hw_emu), or hardware (hw)
TARGET := sw_emu

PLATFORM := $(BUILD)/platform/$(NAME).xpfm

SYSROOT := $(BUILD)/sysroot

VPPFLAGS = -t $(TARGET)
VPPFLAGS += --platform $(realpath $(PLATFORM))
VPPFLAGS += --config config.ini
VPPFLAGS += --temp_dir $(@D)
VPPFLAGS += --log_dir $(@D)
ifneq ($(TARGET),hw)
    VPPFLAGS += -g
endif

# Compiled kernel object files
XOBJS := $(foreach obj,$(patsubst src/%.c,%.xo,$(wildcard src/kernels/*/*.c)),$(BUILD)/$(TARGET)/$(obj))

.PHONY: all
all: host xclbin emconfig

.PHONY: host
host: $(BUILD)/$(TARGET)/host
$(BUILD)/$(TARGET)/host: $(wildcard src/host/*.cpp src/host/*.h) $(SYSROOT)
	$(MAKE) SYSROOT=$(realpath $(SYSROOT)) -C src/host
	mkdir -p $(@D)
	cp src/host/host $@

.PHONY: platform
platform: $(PLATFORM)
$(PLATFORM): scripts/create_platform.tcl $(BUILD)/$(NAME).xsa $(BUILD)/boot/image.ub $(BUILD)/boot/fsbl.elf $(BUILD)/boot/pmufw.elf $(BUILD)/boot/u-boot.elf $(BUILD)/boot/bl31.elf $(SYSROOT) pfm/linux.bif pfm/qemu/qemu_args.txt pfm/qemu/pmu_args.txt
	xsct $< $(BUILD)/$(NAME).xsa $(WORKSPACE) $(BUILD)

.PHONY: xclbin
xclbin: $(BUILD)/$(TARGET)/$(NAME).xclbin
$(BUILD)/$(TARGET)/$(NAME).xclbin: config.ini $(XOBJS)
	v++ $(VPPFLAGS) -l -o $@ $(XOBJS)

.PHONY: kernels
kernels: $(XOBJS)
$(BUILD)/$(TARGET)/kernels/%.xo: $(PLATFORM) src/kernels/%.c src/kernels/%.h
	v++ $(VPPFLAGS) -c -I src/kernels/$(*D) -k $(*F) -o $@ src/kernels/$*.c

.PHONY: sysroot
sysroot: $(SYSROOT)
$(SYSROOT): petalinux/images/linux/rootfs.tar.gz
	-$(RM) -rf $@
	mkdir -p $@
	tar -C $@ -xf $<
	@touch $@

.PHONY: emconfig
emconfig: $(BUILD)/$(TARGET)/emconfig.json
$(BUILD)/$(TARGET)/emconfig.json: $(PLATFORM)
	emconfigutil --platform $(PLATFORM) --od $(@D)

.PHONY: sdcard
sdcard: host xclbin _vimage/emulation/.sdcard
_vimage/emulation/.sdcard: _vimage/emulation/sd_card.manifest
	sed -i 's!$(PWD)/$(NAME).xclbin!$(PWD)/$(BUILD)/$(TARGET)/$(NAME).xclbin!' _vimage/emulation/sd_card.manifest
	echo '$(PWD)/xrt.ini' >> _vimage/emulation/sd_card.manifest
	echo '$(PWD)/$(BUILD)/$(TARGET)/host' >> _vimage/emulation/sd_card.manifest
	echo 'export XILINX_XRT=/usr' >> _vimage/emulation/init.sh
	echo './host $(NAME).xclbin' >> _vimage/emulation/init.sh
	@touch $@

.PHONY: run
run: sdcard
	launch_emulator -no-reboot -runtime ocl -t $(TARGET) -forward-port 1440 1534

.PHONY: clean
clean:
	-$(RM) -r *.log *.jou *.str .Xil

.PHONY: cleanhost
cleanhost:
	-$(RM) $(BUILD)/$(TARGET)/host
	$(MAKE) -C src/host clean

.PHONY: cleankernels
cleankernels:
	-$(RM) -rf $(XOBJS) $(BUILD)/$(TARGET)/$(NAME).xclbin _vimage

.PHONY: cleanall
cleanall: clean cleanhost cleankernels
	-$(RM) -rf emulation pl_script.sh start_simulation.sh

$(BUILD)/$(NAME).xsa: scripts/create_xsa.tcl
	vivado -mode tcl -source $< -tclargs $(NAME)

$(BUILD)/boot:
	mkdir -p $@

$(BUILD)/boot/image.ub: petalinux/images/linux/image.ub | $(BUILD)/boot
	cp $< $@

$(BUILD)/boot/%.elf: petalinux/images/linux/%.elf | $(BUILD)/boot
	cp $< $@

$(BUILD)/boot/fsbl.elf: petalinux/images/linux/zynqmp_fsbl.elf | $(BUILD)/boot
	cp $< $@

petalinux/images/linux/%: petalinux/project-spec/hw-description/system.xsa
	petalinux-build -p petalinux

petalinux/project-spec/hw-description/system.xsa: $(BUILD)/$(NAME).xsa
	petalinux-config --get-hw-description=$(realpath $(<D)) -p petalinux --silentconfig
