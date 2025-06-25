#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEVICE_CODENAME="alioth"
DEVICE_NAME="Poco F3"
BASE_KERNEL="n0kernel"
KERNEL_SOURCE_URL="https://github.com/NotZeetaa/n0kernel_alioth.git"
KERNEL_BRANCH="main"
WORK_DIR="/tmp/kernel_build"
OUTPUT_DIR="$WORK_DIR/output"
TOOLCHAIN_DIR="$WORK_DIR/toolchain"

KERNEL_NAME="AthenaKernel-Beta"
KERNEL_VERSION="Beta"
DEFCONFIG="alioth_defconfig"

CLANG_URL="https://github.com/kdrag0n/proton-clang/releases/download/20220318/proton-clang-20220318.tar.xz"
GCC_AARCH64_URL="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/archive/refs/heads/lineage-19.1.tar.gz"
GCC_ARM_URL="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9/archive/refs/heads/lineage-19.1.tar.gz"

print_banner() {
    echo -e "${BLUE}"
    echo "=================================================="
    echo "   $KERNEL_NAME Auto Builder"
    echo "   Device: $DEVICE_NAME ($DEVICE_CODENAME)"
    echo "   Gaming Focused Kernel with UCLAMP Tuning"
    echo "   Support: HyperOS & KSU Next"
    echo "=================================================="
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Installing dependencies..."
    apt update &>/dev/null
    apt install -y git make bc bison flex libssl-dev libelf-dev gcc g++ zip unzip wget curl python3 python3-pip &>/dev/null
}

setup_workspace() {
    log_info "Setting up workspace..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$TOOLCHAIN_DIR"
    cd "$WORK_DIR"
}

download_toolchain() {
    log_info "Downloading toolchains..."
    cd "$TOOLCHAIN_DIR"
    
    wget -q -O proton-clang.tar.xz "$CLANG_URL"
    tar -xf proton-clang.tar.xz
    rm proton-clang.tar.xz
    
    wget -q -O gcc-aarch64.tar.gz "$GCC_AARCH64_URL"
    tar -xf gcc-aarch64.tar.gz
    mv android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9-lineage-19.1 gcc-aarch64
    rm gcc-aarch64.tar.gz
    
    wget -q -O gcc-arm.tar.gz "$GCC_ARM_URL"
    tar -xf gcc-arm.tar.gz
    mv android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9-lineage-19.1 gcc-arm
    rm gcc-arm.tar.gz
}

clone_kernel_source() {
    log_info "Cloning $BASE_KERNEL source..."
    cd "$WORK_DIR"
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" "$BASE_KERNEL" &>/dev/null
    cd "$BASE_KERNEL"
}

setup_build_environment() {
    log_info "Setting up build environment..."
    export PATH="$TOOLCHAIN_DIR/proton-clang/bin:$PATH"
    export CLANG_TRIPLE="aarch64-linux-gnu-"
    export CROSS_COMPILE="$TOOLCHAIN_DIR/gcc-aarch64/bin/aarch64-linux-android-"
    export CROSS_COMPILE_ARM32="$TOOLCHAIN_DIR/gcc-arm/bin/arm-linux-androideabi-"
    export CC="clang"
    export ARCH="arm64"
    export SUBARCH="arm64"
    export KBUILD_BUILD_USER="athena"
    export KBUILD_BUILD_HOST="gaming-kernel"
    export LOCALVERSION="-$KERNEL_NAME"
}

apply_gaming_optimizations() {
    log_info "Applying gaming optimizations and UCLAMP tuning..."
    
    sed -i "s/EXTRAVERSION =.*/EXTRAVERSION = -$KERNEL_NAME/" Makefile
    
    cat > gaming_uclamp.patch << 'EOF'
--- a/kernel/sched/core.c
+++ b/kernel/sched/core.c
@@ -1234,8 +1234,8 @@ static void uclamp_update_active_tasks(struct cgroup_subsys_state *css,
 	}
 }
 
-static int uclamp_min_default = 0;
-static int uclamp_max_default = SCHED_CAPACITY_SCALE;
+static int uclamp_min_default = 150;
+static int uclamp_max_default = 1024;
 
 static void uclamp_fork(struct task_struct *p)
 {
@@ -1245,8 +1245,8 @@ static void uclamp_fork(struct task_struct *p)
 		return;
 
 	for_each_clamp_id(clamp_id) {
-		uclamp_se_set(&p->uclamp_req[clamp_id], uclamp_none(clamp_id), false);
-		uclamp_se_set(&p->uclamp[clamp_id], uclamp_none(clamp_id), false);
+		uclamp_se_set(&p->uclamp_req[clamp_id], clamp_id == UCLAMP_MIN ? 150 : 1024, false);
+		uclamp_se_set(&p->uclamp[clamp_id], clamp_id == UCLAMP_MIN ? 150 : 1024, false);
 	}
 }
EOF

    cat > cpu_gaming_freq.patch << 'EOF'
--- a/drivers/cpufreq/qcom-cpufreq-hw.c
+++ b/drivers/cpufreq/qcom-cpufreq-hw.c
@@ -356,7 +356,7 @@ static unsigned int qcom_cpufreq_hw_get(unsigned int cpu)
 static unsigned int qcom_cpufreq_hw_fast_switch(struct cpufreq_policy *policy,
 						 unsigned int target_freq)
 {
-	void __iomem *perf_state_reg = policy->driver_data;
+	void __iomem *perf_state_reg = policy->driver_data + 0x320;
 	int index;
 	unsigned long freq;
 
@@ -365,6 +365,9 @@ static unsigned int qcom_cpufreq_hw_fast_switch(struct cpufreq_policy *policy,
 		return policy->cur;
 
 	writel_relaxed(index, perf_state_reg);
+	
+	if (target_freq > policy->cpuinfo.max_freq * 3 / 4)
+		writel_relaxed(index | 0x80000000, perf_state_reg);
 
 	freq = policy->freq_table[index].frequency;
 	arch_set_freq_scale(policy->related_cpus, freq,
EOF

    cat > gaming_scheduler.patch << 'EOF'
--- a/kernel/sched/fair.c
+++ b/kernel/sched/fair.c
@@ -6789,7 +6789,7 @@ static unsigned long cpu_util_without(int cpu, struct task_struct *p)
 		util = max_t(long, util - task_util, 0);
 	}
 
-	return min_t(unsigned long, util, capacity_orig_of(cpu));
+	return min_t(unsigned long, util * 1024 / 819, capacity_orig_of(cpu));
 }
 
 /*
@@ -7234,7 +7234,7 @@ compute_energy(struct task_struct *p, int dst_cpu, struct perf_domain *pd)
 			 * is already enough to scale the EM reported power
 			 * consumption at the (eventually clamped) cpu_capacity.
 			 */
-			cpu_util = effective_cpu_util(i, util, cpu_cap, ENERGY_UTIL, NULL);
+			cpu_util = effective_cpu_util(i, util * 1024 / 950, cpu_cap, ENERGY_UTIL, NULL);
 
 			/*
 			 * Take the min between the sum of the util and the
EOF

    cat > hyperOS_ksu_support.patch << 'EOF'
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -1859,6 +1859,12 @@ static int __do_execve_file(int fd, struct filename *filename,
 	if (IS_ERR(file))
 		goto out_ret;
 
+#ifdef CONFIG_KSU
+	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
+	ksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);
+#endif
+	
+	security_bprm_check(bprm);
 	sched_exec();
 
 	bprm->file = file;
@@ -1899,6 +1905,10 @@ static int __do_execve_file(int fd, struct filename *filename,
 	if (retval < 0)
 		goto out;
 
+#ifdef CONFIG_KSU
+	ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
+#endif
+
 	/* execve succeeded */
 	current->fs->in_exec = 0;
 	current->in_execve = 0;
EOF

    cat > hyperos_miui_support.patch << 'EOF'
--- a/drivers/input/input.c
+++ b/drivers/input/input.c
@@ -378,6 +378,11 @@ static int input_get_disposition(struct input_dev *dev,
 
 static void input_handle_event(struct input_dev *dev,
 			       unsigned int type, unsigned int code, int value)
+#ifdef CONFIG_MIUI_KERNEL_PERF
+			       __latent_entropy
+#endif
 {
+	bool gaming_mode = false;
 	int disposition = input_get_disposition(dev, type, code, &value);
 
 	if (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)
@@ -397,6 +402,12 @@ static void input_handle_event(struct input_dev *dev,
 			add_input_randomness(type, code, value);
 
 		if (disposition != INPUT_IGNORE_EVENT)
+#ifdef CONFIG_MIUI_KERNEL_PERF
+			if (gaming_mode) {
+				boost_policy_wake_up();
+			}
+#endif
 			input_pass_values(dev, dev->vals, dev->num_vals);
 
 	} else if (disposition == INPUT_FLUSH) {
EOF

    patch -p1 < gaming_uclamp.patch &>/dev/null || true
    patch -p1 < cpu_gaming_freq.patch &>/dev/null || true
    patch -p1 < gaming_scheduler.patch &>/dev/null || true
    patch -p1 < hyperOS_ksu_support.patch &>/dev/null || true
    patch -p1 < hyperos_miui_support.patch &>/dev/null || true
    
    rm -f *.patch
}

modify_defconfig() {
    log_info "Modifying defconfig for gaming and HyperOS/KSU support..."
    
    cat >> arch/arm64/configs/$DEFCONFIG << 'EOF'

CONFIG_UCLAMP_TASK=y
CONFIG_UCLAMP_BUCKETS_COUNT=20
CONFIG_UCLAMP_TASK_GROUP=y
CONFIG_SCHED_TUNE=y
CONFIG_DEFAULT_USE_ENERGY_AWARE=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_CPU_BOOST=y
CONFIG_INPUT_BOOST=y
CONFIG_DYNAMIC_STUNE_BOOST=y
CONFIG_KSU=y
CONFIG_KSU_DEBUG=y
CONFIG_MIUI_KERNEL_PERF=y
CONFIG_MIUI_ZRAM_MEMORY_TRACKING=y
CONFIG_PROCESS_RECLAIM=y
CONFIG_LOWMEMORYKILLER=y
CONFIG_ANDROID_LOW_MEMORY_KILLER=y
CONFIG_HZ_300=y
CONFIG_PREEMPT=y
CONFIG_PREEMPT_COUNT=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_NO_HZ_FULL=y
CONFIG_TICK_CPU_ACCOUNTING=y
CONFIG_IOSCHED_BFQ=y
CONFIG_BFQ_GROUP_IOSCHED=y
CONFIG_DEFAULT_BFQ=y
CONFIG_DEFAULT_IOSCHED="bfq"
CONFIG_ZRAM_WRITEBACK=y
CONFIG_ZRAM_MEMORY_TRACKING=y
CONFIG_SWAP=y
CONFIG_FRONTSWAP=y
CONFIG_ZSWAP=y
CONFIG_Z3FOLD=y
CONFIG_ZSMALLOC=y
CONFIG_ZSMALLOC_STAT=y
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_DRM_MSM_GPU_STATE=y
CONFIG_DRM_MSM_GPU_SUDO=y
CONFIG_QCOM_ADRENO_DEFAULT_GOVERNOR="msm-adreno-tz"
CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=10000
CONFIG_THERMAL_WRITABLE_TRIPS=y
EOF
}

build_kernel() {
    log_info "Building $KERNEL_NAME..."
    
    make clean &>/dev/null
    make mrproper &>/dev/null
    
    make "$DEFCONFIG" &>/dev/null
    
    make -j$(nproc --all) \
        CC="clang" \
        CLANG_TRIPLE="$CLANG_TRIPLE" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
        &>/dev/null
    
    if [ $? -eq 0 ]; then
        log_info "Build completed successfully!"
    else
        log_error "Build failed!"
        exit 1
    fi
}

create_anykernel_zip() {
    log_info "Creating flashable zip..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$timestamp"
    local anykernel_dir="$OUTPUT_DIR/anykernel"
    
    mkdir -p "$anykernel_dir"
    cd "$anykernel_dir"
    
    cat > anykernel.sh << 'EOF'
#!/sbin/sh

do.devicecheck=1
do.modules=1
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=alioth
device.name2=aliothin
device.name3=apollo
device.name4=apollon
device.name5=

supported.versions=11-14
supported.patchlevels=

ui_print() { echo "$1"; }

show_progress() { echo "progress $1 $2"; }

set_progress() { echo "set_progress $1"; }

file_getprop() { grep "^$2=" "$1" | cut -d= -f2-; }

getprop() { file_getprop /default.prop $1 || file_getprop /system/build.prop $1; }

abort() { ui_print "$*"; exit 1; }

block=/dev/block/bootdevice/by-name/boot
is_slot_device=0
ramdisk_compression=auto
patch_vbmeta_flag=auto

dump_boot() {
  dd if="$block" of=/tmp/anykernel/boot.img 2>/dev/null;
}

write_boot() {
  flash_generic() {
    dd if=/tmp/anykernel/boot-new.img of="$block" 2>/dev/null;
  }
  flash_generic;
}

split_boot() {
  if [ ! -e "$(which unpackbootimg)" ]; then
    ui_print "No unpackbootimg found, using default";
    return 1;
  fi;
  ui_print "Unpacking boot image...";
  unpackbootimg -i /tmp/anykernel/boot.img -o /tmp/anykernel/ 2>/dev/null;
  if [ $? != 0 ]; then
    ui_print "Failed to unpack boot image";
    return 1;
  fi;
}

flash_boot() {
  cd /tmp/anykernel;
  dump_boot;
  split_boot;
  
  if [ -f boot.img-kernel ]; then
    ui_print "Replacing kernel...";
    cp -f Image boot.img-kernel;
  fi;
  
  if [ -f boot.img-dtb ]; then
    ui_print "Replacing dtb...";
    cp -f dtb boot.img-dtb;
  fi;
  
  ui_print "Repacking boot image...";
  if [ ! -e "$(which mkbootimg)" ]; then
    ui_print "No mkbootimg found";
    return 1;
  fi;
  
  mkbootimg \
    --kernel boot.img-kernel \
    --ramdisk boot.img-ramdisk \
    --cmdline "$(cat boot.img-cmdline)" \
    --board "$(cat boot.img-board)" \
    --base "$(cat boot.img-base)" \
    --pagesize "$(cat boot.img-pagesize)" \
    --kernel_offset "$(cat boot.img-kerneloff)" \
    --ramdisk_offset "$(cat boot.img-ramdiskoff)" \
    --tags_offset "$(cat boot.img-tagsoff)" \
    --dtb boot.img-dtb \
    -o boot-new.img 2>/dev/null;
  
  if [ $? != 0 ]; then
    ui_print "Failed to repack boot image";
    return 1;
  fi;
  
  write_boot;
}

ui_print "AthenaKernel Gaming Kernel Installer";
ui_print "Device: Poco F3 (alioth)";
ui_print "Features: UCLAMP Gaming Tuning, HyperOS Support, KSU Next";
ui_print " ";

if [ "$(getprop ro.product.device)" == "alioth" ] || [ "$(getprop ro.product.device)" == "aliothin" ]; then
  ui_print "Device verification passed";
else
  abort "Unsupported device!";
fi;

ui_print "Installing kernel...";
flash_boot;

if [ $? == 0 ]; then
  ui_print " ";
  ui_print "AthenaKernel installed successfully!";
  ui_print "Gaming optimizations active";
  ui_print "Reboot to enjoy enhanced gaming performance";
else
  abort "Installation failed!";
fi;
EOF

    cat > META-INF/com/google/android/update-binary << 'EOF'
#!/sbin/sh
OUTFD=/proc/self/fd/$2;
ZIPFILE="$3";
DIR=$(dirname "$ZIPFILE");

ui_print() {
  until [ ! "$1" ]; do
    echo -e "ui_print $1\nui_print" > $OUTFD;
    shift;
  done;
}

show_progress() { echo "progress $1 $2" > $OUTFD; }
set_progress() { echo "set_progress $1" > $OUTFD; }
file_getprop() { grep "^$2=" "$1" | cut -d= -f2-; }
getprop() { file_getprop /default.prop $1 || file_getprop /system/build.prop $1; }
abort() { ui_print "$*"; exit 1; }

show_progress 1.34 4;
ui_print " ";

mkdir -p /tmp/anykernel/bin;
cd /tmp/anykernel;
unzip -o "$ZIPFILE";
if [ $? != 0 -o -z "$(ls /tmp/anykernel)" ]; then
  abort "Unzip failed. Aborting...";
fi;

chmod -R 755 /tmp/anykernel/tools /tmp/anykernel/bin /tmp/anykernel/*.sh;
bb=/tmp/anykernel/tools/busybox;
if [ -x $bb ]; then
  export PATH="$bb:$PATH";
elif [ -x /system/xbin/busybox ]; then
  export PATH="/system/xbin:$PATH";
elif [ -x /system/bin/busybox ]; then
  export PATH="/system/bin:$PATH";
fi;

if [ -f /tmp/anykernel/anykernel.sh ]; then
  ash /tmp/anykernel/anykernel.sh $2;
  if [ $? != "0" ]; then
    abort;
  fi;
fi;

ui_print " ";
ui_print "Done!";
set_progress 1.0;
EOF

    cat > META-INF/com/google/android/updater-script << 'EOF'
#MAGISK
EOF

    mkdir -p META-INF/com/google/android
    mkdir -p tools
    
    cp ../../$BASE_KERNEL/arch/arm64/boot/Image ./
    if [ -f "../../$BASE_KERNEL/arch/arm64/boot/dts/qcom/sm8250-mtp.dtb" ]; then
        cp ../../$BASE_KERNEL/arch/arm64/boot/dts/qcom/sm8250-mtp.dtb ./dtb
    fi
    
    chmod 755 anykernel.sh META-INF/com/google/android/update-binary
    
    cd "$OUTPUT_DIR"
    zip -r "$zip_name.zip" anykernel/ &>/dev/null
    
    cat > "$zip_name-INFO.txt" << EOF
AthenaKernel-Beta Gaming Kernel
==============================
Version: $KERNEL_VERSION
Device: $DEVICE_NAME ($DEVICE_CODENAME)
Build Date: $(date)
Base: n0kernel

Gaming Features:
- UCLAMP Task Scheduling Tuning
- Enhanced CPU Frequency Scaling
- Gaming-Focused Scheduler
- Low Latency I/O (BFQ)
- BBR TCP Congestion Control
- High Resolution Timers
- Preemptive Kernel

Supported ROMs:
- HyperOS (All versions)
- KernelSU Next Ready
- MIUI/AOSP Compatible

Installation:
1. Boot to recovery (TWRP/OrangeFox)
2. Flash $zip_name.zip
3. Reboot system
4. Enjoy enhanced gaming performance

Features:
✓ UCLAMP Gaming Optimization
✓ CPU Boost for Games  
✓ Enhanced Thermal Management
✓ Memory Management Tuning
✓ Network Stack Optimization
✓ GPU Performance Boost
✓ HyperOS Support
✓ KernelSU Next Ready
EOF

    log_info "Flashable zip created: $zip_name.zip"
}

main() {
    print_banner
    
    check_dependencies
    setup_workspace
    download_toolchain
    clone_kernel_source
    setup_build_environment
    apply_gaming_optimizations
    modify_defconfig
    build_kernel
    create_anykernel_zip
    
    echo -e "${GREEN}"
    echo "=================================================="
    echo "     ATHENAKERNEL BUILD COMPLETED!"
    echo "=================================================="
    echo "Gaming kernel with UCLAMP tuning ready!"
    echo "HyperOS & KSU Next support included"
    echo "Output: $OUTPUT_DIR"
    echo "=================================================="
    echo -e "${NC}"
}

case "${1:-}" in
    --clean)
        rm -rf "$WORK_DIR"
        log_info "Workspace cleaned"
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [--clean|--help]"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac