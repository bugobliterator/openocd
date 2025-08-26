#!/bin/bash
# Common dependency building script for OpenOCD static builds
# Usage: build-deps.sh <platform> <host-triplet>
# Platform: windows, linux, darwin
# Host triplet: e.g., x86_64-w64-mingw32, x86_64-linux-gnu, etc.

set -e

PLATFORM="$1"
HOST="$2"
SYSROOT="${SYSROOT:-$(pwd)/sysroot}"
MAKE_JOBS="${MAKE_JOBS:-2}"

# Configuration defaults
LIBUSB1_CONFIG="${LIBUSB1_CONFIG:---enable-static --disable-shared}"
HIDAPI_CONFIG="${HIDAPI_CONFIG:---enable-static --disable-shared HIDAPI_BUILD_HIDTEST=FALSE HIDAPI_WITH_TESTS=FALSE}"
LIBFTDI_CONFIG="${LIBFTDI_CONFIG:--DSTATICLIBS=ON -DBUILD_SHARED_LIBS=OFF -DEXAMPLES=OFF -DFTDI_EEPROM=OFF}"
CAPSTONE_CONFIG="${CAPSTONE_CONFIG:-CAPSTONE_BUILD_CORE_ONLY=yes CAPSTONE_STATIC=yes CAPSTONE_SHARED=no}"
LIBJAYLINK_CONFIG="${LIBJAYLINK_CONFIG:---enable-static --disable-shared}"
JIMTCL_CONFIG="${JIMTCL_CONFIG:---with-ext=json --minimal --disable-ssl}"

mkdir -p "$SYSROOT/usr"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig"

# Platform-specific setup
case "$PLATFORM" in
    windows)
        export CC="$HOST-gcc"
        export CXX="$HOST-g++"
        export AR="$HOST-ar"
        export STRIP="$HOST-strip"
        export CFLAGS="-static-libgcc -static-libstdc++"
        export CXXFLAGS="-static-libgcc -static-libstdc++"
        export LDFLAGS="-static-libgcc -static-libstdc++"
        HOST_FLAG="--host=$HOST"
        ;;
    linux)
        if [[ "$HOST" != *"$(uname -m)"* ]]; then
            # Cross-compilation
            ARCH_PREFIX="${HOST%-linux-gnu}"
            export CC="$ARCH_PREFIX-linux-gnu-gcc"
            export CXX="$ARCH_PREFIX-linux-gnu-g++"
            export AR="$ARCH_PREFIX-linux-gnu-ar"
            export STRIP="$ARCH_PREFIX-linux-gnu-strip"
            HOST_FLAG="--host=$HOST"
        else
            # Native compilation
            HOST_FLAG=""
        fi
        # Allow shared system libraries like libudev
        export CFLAGS=""
        export CXXFLAGS=""
        export LDFLAGS=""
        # Use shared libraries on Linux
        LIBUSB1_CONFIG="--enable-shared --disable-static"
        HIDAPI_CONFIG="--enable-shared --disable-static"
        LIBFTDI_CONFIG="-DSTATICLIBS=OFF -DBUILD_SHARED_LIBS=ON -DEXAMPLES=OFF -DFTDI_EEPROM=OFF"
        LIBJAYLINK_CONFIG="--enable-shared --disable-static"
        ;;
    darwin)
        if [[ "$HOST" == *"arm64"* ]]; then
            export CFLAGS="-arch arm64"
            export CXXFLAGS="-arch arm64"
            export LDFLAGS="-arch arm64"
        else
            export CFLAGS="-arch x86_64"
            export CXXFLAGS="-arch x86_64"
            export LDFLAGS="-arch x86_64"
        fi
        HOST_FLAG=""
        # Add macOS framework flags
        export LDFLAGS="$LDFLAGS -framework CoreFoundation -framework IOKit -framework Security -framework AppKit"
        ;;
esac

echo "Building dependencies for $PLATFORM ($HOST)"

# Build libusb1
if [ -d "$LIBUSB1_SRC" ]; then
    echo "Building libusb1..."
    mkdir -p libusb1 && cd libusb1
    $LIBUSB1_SRC/configure --prefix=/usr $HOST_FLAG $LIBUSB1_CONFIG
    make -j $MAKE_JOBS
    make install DESTDIR=$SYSROOT
    rm -f $SYSROOT/usr/lib/*.la
    cd ..
fi

# Build hidapi (all platforms)
if [ -d "$HIDAPI_SRC" ]; then
    echo "Building hidapi..."
    mkdir -p hidapi && cd hidapi
    export CPPFLAGS="-I$SYSROOT/usr/include -I$SYSROOT/usr/include/libusb-1.0"
    export LDFLAGS="$LDFLAGS -L$SYSROOT/usr/lib"
    export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig"
    $HIDAPI_SRC/configure --prefix=/usr $HOST_FLAG $HIDAPI_CONFIG
    make -j $MAKE_JOBS libs || make -j $MAKE_JOBS
    make install DESTDIR=$SYSROOT
    rm -f $SYSROOT/usr/lib/*.la
    cd ..
fi

# Build libftdi (skip on Windows due to symbol conflicts)
if [ -d "$LIBFTDI_SRC" ] && [ "$PLATFORM" != "windows" ]; then
    echo "Building libftdi..."
    mkdir -p libftdi && cd libftdi
    
    # Set libusb paths explicitly for CMake
    export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig"
    export LIBUSB_1_INCLUDE_DIRS="$SYSROOT/usr/include/libusb-1.0"
    export LIBUSB_1_LIBRARIES="$SYSROOT/usr/lib/libusb-1.0.a"

    # Linux/Darwin CMake build
    cmake $LIBFTDI_SRC \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DLIBUSB_INCLUDE_DIR="$SYSROOT/usr/include/libusb-1.0" \
        -DLIBUSB_LIBRARIES="$SYSROOT/usr/lib/libusb-1.0.a" \
        -DLIBUSB_1_INCLUDE_DIRS="$SYSROOT/usr/include/libusb-1.0" \
        -DLIBUSB_1_LIBRARIES="$SYSROOT/usr/lib/libusb-1.0.a" \
        $LIBFTDI_CONFIG
    
    make -j $MAKE_JOBS
    make install DESTDIR=$SYSROOT
    cd ..
fi

# Build capstone
if [ -d "$CAPSTONE_SRC" ]; then
    echo "Building capstone..."
    mkdir -p capstone && cd capstone
    cp -r $CAPSTONE_SRC/* .
    if [ "$PLATFORM" = "windows" ]; then
        CROSS="$HOST-" make -j $MAKE_JOBS $CAPSTONE_CONFIG
        CROSS="$HOST-" make install DESTDIR=$SYSROOT PREFIX=/usr $CAPSTONE_CONFIG
    else
        make -j $MAKE_JOBS $CAPSTONE_CONFIG
        make install DESTDIR=$SYSROOT PREFIX=/usr $CAPSTONE_CONFIG
    fi
    cd ..
fi

# Build libjaylink
if [ -d "$LIBJAYLINK_SRC" ]; then
    echo "Building libjaylink..."
    mkdir -p libjaylink && cd libjaylink
    export CPPFLAGS="-I$SYSROOT/usr/include -I$SYSROOT/usr/include/libusb-1.0 $CFLAGS"
    export LDFLAGS="$LDFLAGS -L$SYSROOT/usr/lib"
    $LIBJAYLINK_SRC/configure --prefix=/usr $HOST_FLAG $LIBJAYLINK_CONFIG
    make -j $MAKE_JOBS
    make install DESTDIR=$SYSROOT
    rm -f $SYSROOT/usr/lib/*.la
    cd ..
fi

# Build jimtcl
if [ -d "$JIMTCL_SRC" ]; then
    echo "Building jimtcl..."
    mkdir -p jimtcl && cd jimtcl
    if [ "$PLATFORM" = "windows" ]; then
        CC="$CC" $JIMTCL_SRC/configure --prefix=/usr $HOST_FLAG $JIMTCL_CONFIG
    else
        $JIMTCL_SRC/configure --prefix=/usr $HOST_FLAG $JIMTCL_CONFIG
    fi
    make -j $MAKE_JOBS
    # Install manually to handle missing build-jim-ext gracefully
    make install DESTDIR=$SYSROOT || {
        echo "Warning: jimtcl install failed, trying manual installation..."
        mkdir -p $SYSROOT/usr/lib $SYSROOT/usr/include $SYSROOT/usr/bin
        cp -f libjim.a $SYSROOT/usr/lib/ 2>/dev/null || true
        cp -f $JIMTCL_SRC/jim*.h $SYSROOT/usr/include/ 2>/dev/null || true
        cp -f jim-config.h $SYSROOT/usr/include/ 2>/dev/null || true
        cp -f jimsh* $SYSROOT/usr/bin/ 2>/dev/null || true
    }
    cd ..
fi

echo "Dependencies built successfully in $SYSROOT"