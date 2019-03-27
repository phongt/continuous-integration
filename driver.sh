#!/usr/bin/env bash

set -eu

setup_variables() {
  while [[ ${#} -ge 1 ]]; do
    case ${1} in
      "AR="*|"ARCH="*|"CC="*|"LD="*|"OBJCOPY"=*|"REPO="*) export "${1?}" ;;
      "-c"|"--clean") cleanup=true ;;
      "-j"|"--jobs") shift; jobs=$1 ;;
      "-j"*) jobs=${1/-j} ;;
      "-h"|"--help")
        cat usage.txt
        exit 0 ;;
    esac

    shift
  done

  # Turn on debug mode after parameters in case -h was specified
  set -x

  # torvalds/linux is the default repo if nothing is specified
  case ${REPO:=linux} in
    "common-"*)
      branch=android-${REPO##*-}
      tree=common
      url=https://android.googlesource.com/kernel/${tree} ;;
    "linux")
      owner=torvalds
      tree=linux ;;
    "linux-next")
      owner=next
      tree=linux-next ;;
    "4.4"|"4.9"|"4.14"|"4.19")
      owner=stable
      branch=linux-${REPO}.y
      tree=linux ;;
  esac
  [[ -z "${url:-}" ]] && url=git://git.kernel.org/pub/scm/linux/kernel/git/${owner}/${tree}.git

  # arm64 is the current default if nothing is specified
  case ${ARCH:=arm64} in
    "arm32_v5")
      config=multi_v5_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine palmetto-bmc
                     -no-reboot
                     -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-palmetto.dtb"
                     -initrd "images/arm/rootfs.cpio" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm32_v6")
      config=aspeed_g5_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine romulus-bmc
                     -no-reboot
                     -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-romulus.dtb"
                     -initrd "images/arm/rootfs.cpio" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm32_v7")
      config=multi_v7_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine virt
                     -no-reboot
                     -drive "file=images/arm/rootfs.ext4,format=raw,id=rootfs,if=none"
                     -device "virtio-blk-device,drive=rootfs"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm64")
      case ${REPO} in
        common-*) config=cuttlefish_defconfig ;;
        *) config=defconfig ;;
      esac
      image_name=Image.gz
      qemu="qemu-system-aarch64"
      qemu_ram=512m
      qemu_cmdline=( -cpu cortex-a57
                     -drive "file=images/arm64/rootfs.ext4,format=raw"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export CROSS_COMPILE=aarch64-linux-gnu- ;;

    "x86_64")
      case ${REPO} in
        common-*)
          config=x86_64_cuttlefish_defconfig
          qemu_cmdline=( -append "console=ttyS0"
                         -initrd "images/x86_64/rootfs.cpio" ) ;;
        *)
          config=defconfig
          qemu_cmdline=( -drive "file=images/x86_64/rootfs.ext4,format=raw,if=ide"
                         -append "console=ttyS0 root=/dev/sda" ) ;;
      esac
      image_name=bzImage
      qemu="qemu-system-x86_64"
      qemu_ram=512m ;;
    "ppc32")
      config=ppc44x_defconfig
      image_name=zImage
      qemu="qemu-system-ppc"
      qemu_ram=128m
      qemu_cmdline=( -machine bamboo
                     -append "console=ttyS0"
                     -no-reboot
                     -initrd "images/ppc32/rootfs.cpio" )
      export ARCH=powerpc
      export CROSS_COMPILE=powerpc-linux-gnu- ;;

    "ppc64le")
      config=powernv_defconfig
      image_name=zImage.epapr
      qemu="qemu-system-ppc64"
      qemu_ram=2G
      qemu_cmdline=( -machine powernv
                     -device "ipmi-bmc-sim,id=bmc0"
                     -device "isa-ipmi-bt,bmc=bmc0,irq=10"
                     -L images/ppc64le/ -bios skiboot.lid
                     -initrd images/ppc64le/rootfs.cpio )
      export ARCH=powerpc
      export CROSS_COMPILE=powerpc64le-linux-gnu- ;;

    # Unknown arch, error out
    *)
      echo "Unknown ARCH specified!"
      exit 1 ;;
  esac
  export ARCH=${ARCH}
}

check_dependencies() {
  # Check for existence of needed binaries
  command -v nproc
  command -v "${CROSS_COMPILE:-}"as
  command -v ${qemu}
  command -v timeout
  command -v unbuffer

  # Check for LD, CC, OBJCOPY, and AR environmental variables and print the
  # version string of each. If CC, AR, or OBJCOPY don't exist, try to find them.
  # lld isn't ready for all architectures so it's just simpler to fall back to
  # GNU ld when LD isn't specified to avoid architecture specific selection
  # logic.

  "${LD:="${CROSS_COMPILE:-}"ld}" --version

  if [[ -z "${CC:-}" ]]; then
    for CC in clang-9 clang-8 clang-7 clang; do
      command -v ${CC} &>/dev/null && break
    done
  fi
  ${CC} --version 2>/dev/null || {
    set +x
    echo
    echo "Looks like ${CC} could not be found in PATH!"
    echo
    echo "Please install as recent a version of clang as you can from your distro or"
    echo "properly specify the CC variable to point to the correct clang binary."
    echo
    echo "If you don't want to install clang, you can either download AOSP's prebuilt"
    echo "clang [1] or build it from source [2] then add the bin folder to your PATH."
    echo
    echo "[1]: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/"
    echo "[2]: https://github.com/ClangBuiltLinux/linux/wiki/Building-Clang-from-source"
    echo
    exit;
  }

  if [[ -z "${AR:-}" ]]; then
    for AR in llvm-ar-9 llvm-ar-8 llvm-ar-7 llvm-ar "${CROSS_COMPILE:-}"ar; do
      command -v ${AR} 2>/dev/null && break
    done
  fi
  check_ar_version
  ${AR} --version

  if [[ -z "${OBJCOPY:-}" ]]; then
    for OBJCOPY in llvm-objcopy-9 llvm-objcopy-8 llvm-objcopy-7 llvm-objcopy "${CROSS_COMPILE:-}"objcopy; do
      command -v ${OBJCOPY} 2>/dev/null && break
    done
  fi
  check_objcopy_version
  ${OBJCOPY} --version
}

# Optimistically check to see that the user has a llvm-ar
# with https://reviews.llvm.org/rL354044. If they don't,
# fall back to GNU ar and let them know.
check_ar_version() {
  if ${AR} --version | grep -q "LLVM" && \
     [[ $(${AR} --version | grep version | sed -e 's/.*LLVM version //g' -e 's/[[:blank:]]*$//' -e 's/\.//g' -e 's/svn//' ) -lt 900 ]]; then
    set +x
    echo
    echo "${AR} found but appears to be too old to build the kernel (needs to be at least 9.0.0)."
    echo
    echo "Please either update llvm-ar from your distro or build it from source!"
    echo
    echo "See https://github.com/ClangBuiltLinux/linux/issues/33 for more info."
    echo
    echo "Falling back to GNU ar..."
    echo
    AR=${CROSS_COMPILE:-}ar
    set -x
  fi
}

# Optimistically check to see that the user has a llvm-objcopy
# with https://reviews.llvm.org/rL357017. If they don't,
# fall back to GNU objcopy and let them know.
check_objcopy_version() {
  if ${OBJCOPY} --version | grep -q "LLVM" && \
     [[ $(${OBJCOPY} --version | grep version | sed -e 's/.*LLVM version //g' -e 's/[[:blank:]]*$//' -e 's/\.//g' -e 's/svn//' ) -lt 900 ]]; then
    set +x
    echo
    echo "${OBJCOPY} found but appears to be too old to build the kernel (needs to be at least 9.0.0)."
    echo
    echo "Please either update llvm-objcopy from your distro or build it from source!"
    echo
    echo "See https://github.com/ClangBuiltLinux/linux/issues/418 for more info."
    echo
    echo "Falling back to GNU objcopy..."
    echo
    OBJCOPY=${CROSS_COMPILE:-}objcopy
    set -x
  fi
}

mako_reactor() {
  # https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/kbuild/kbuild.txt
  time \
  KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
  KBUILD_BUILD_USER=driver \
  KBUILD_BUILD_HOST=clangbuiltlinux \
  make -j"${jobs:-$(nproc)}" CC="${CC}" HOSTCC="${CC}" LD="${LD}" HOSTLD="${HOSTLD:-ld}" AR="${AR}" OBJCOPY="${OBJCOPY}" "${@}"
}

apply_patches() {
  patches_folder=$1
  if [[ -d ${patches_folder} ]]; then
    git apply -v -3 "${patches_folder}"/*.patch
  else
    return 0
  fi
}

build_linux() {
  # Wrap CC in ccache if it is available (it's not strictly required)
  CC="$(command -v ccache) ${CC}"
  [[ ${LD} =~ lld ]] && HOSTLD=${LD}

  if [[ -d ${tree} ]]; then
    cd ${tree}
    git fetch --depth=1 ${url} ${branch:=master}
    git reset --hard FETCH_HEAD
  else
    git clone --depth=1 -b ${branch:=master} --single-branch ${url}
    cd ${tree}
  fi

  git show -s | cat

  apply_patches "../patches/all"
  apply_patches "../patches/${REPO}/${ARCH}"

  # Only clean up old artifacts if requested, the Linux build system
  # is good about figuring out what needs to be rebuilt
  [[ -n "${cleanup:-}" ]] && mako_reactor mrproper
  mako_reactor ${config}
  # If we're using a defconfig, enable some more common config options
  # like debugging, selftests, and common drivers
  if [[ ${config} =~ defconfig ]]; then
    cat ../configs/common.config >> .config
    # Some torture test configs cause issues on x86_64
    [[ $ARCH != "x86_64" ]] && cat ../configs/tt.config >> .config
    # Disable ftrace on arm32: https://github.com/ClangBuiltLinux/linux/issues/35
    [[ $ARCH == "arm" ]] && ./scripts/config -d CONFIG_FTRACE
  fi
  # Make sure we build with CONFIG_DEBUG_SECTION_MISMATCH so that the
  # full warning gets printed and we can file and fix it properly.
  ./scripts/config -e DEBUG_SECTION_MISMATCH
  mako_reactor olddefconfig &>/dev/null
  mako_reactor ${image_name}
  [[ $ARCH =~ arm ]] && mako_reactor dtbs

  cd "${OLDPWD}"
}

boot_qemu() {
  local kernel_image=${tree}/arch/${ARCH}/boot/${image_name}
  test -e ${kernel_image}
  qemu=( timeout 2m unbuffer "${qemu}"
                             -m "${qemu_ram}"
                             "${qemu_cmdline[@]}"
                             -nographic
                             -kernel "${kernel_image}" )
  # For arm64, we want to test booting at both EL1 and EL2
  if [[ ${ARCH} = "arm64" ]]; then
    "${qemu[@]}" -machine virt
    "${qemu[@]}" -machine "virt,virtualization=true"
  else
    "${qemu[@]}"
  fi
}

setup_variables "${@}"
check_dependencies
build_linux
boot_qemu
