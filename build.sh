#!/bin/bash
#
# This script installs the required build-time dependencies
# and builds AppImage
#

small_FLAGS="-Os -ffunction-sections -fdata-sections"
small_LDFLAGS="-s -Wl,--gc-sections"
CC="cc -O2 -Wall -Wno-deprecated-declarations -Wno-unused-result"

STRIP="strip"
INSTALL_DEPENDENCIES=1
STATIC_BUILD=1
JOBS=${JOBS:-1}

while [ $1 ]; do
  case $1 in
    '--debug' | '-d' )
      STRIP="true"
      ;;
    '--no-dependencies' | '-n' )
      INSTALL_DEPENDENCIES=0
      ;;
    '--use-shared-libs' | '-s' )
      STATIC_BUILD=0
      ;;
    '--clean' | '-c' )
      rm -rf build
      git clean -df
      rm -rf squashfuse/* squashfuse/.git
      rm -rf squashfs-tools/* squashfs-tools/.git
      exit
      ;;
    '--help' | '-h' )
      echo 'Usage: ./build.sh [OPTIONS]'
      echo
      echo 'OPTIONS:'
      echo '  -h, --help: Show this help screen'
      echo '  -d, --debug: Build with debug info.'
      echo '  -n, --no-dependencies: Do not try to install distro specific build dependencies.'
      echo '  -s, --use-shared-libs: Use distro provided shared versions of inotify-tools and openssl.'
      echo '  -c, --clean: Clean all artifacts generated by the build.'
      exit
      ;;
  esac

  shift
done

echo $KEY | md5sum

set -e
set -x

HERE="$(dirname "$(readlink -f "${0}")")"
cd "$HERE"

# Install dependencies if enabled
if [ $INSTALL_DEPENDENCIES -eq 1 ]; then
  . ./install-build-deps.sh
fi

# Fetch git submodules
git submodule init
git submodule update

# Clean up from previous run
rm -rf build/ || true

# Build static libraries
if [ $STATIC_BUILD -eq 1 ]; then
  # Build inotify-tools
  if [ ! -e "./inotify-tools-3.14/build/lib/libinotifytools.a" ] ; then
    if [ ! -e "./inotify-tools-3.14/src" ] ; then
      wget -c http://github.com/downloads/rvoicilas/inotify-tools/inotify-tools-3.14.tar.gz
      tar xf inotify-tools-3.14.tar.gz
      # Pull the latest `configure` scripts to handle newer platforms.
      wget "http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD" \
           --output-document=inotify-tools-3.14/config.guess
      wget "http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD" \
             --output-document=inotify-tools-3.14/config.sub
    fi
    cd inotify-tools-3.14
    mkdir -p build/lib
    ./configure --prefix=$(pwd)/build --libdir=$(pwd)/build/lib --enable-shared --enable-static  # disabling shared leads to linking errors?
    make -j$JOBS
    make install
    cd -
  fi

  # Build openssl
  if [ ! -e "./openssl-1.1.0c/build/lib/libssl.a" ] ; then
    wget -c https://www.openssl.org/source/openssl-1.1.0c.tar.gz
    tar xf openssl-1.1.0c.tar.gz
    cd openssl-1.1.0c
    mkdir -p build/lib
    ./config --prefix=$(pwd)/build no-shared
    make -j$JOBS && make install PROCESS_PODS=''
    cd -
  fi
fi

# Build lzma always static because the runtime gets distributed with
# the generated .AppImage file.
if [ ! -e "./xz-5.2.3/build/lib/liblzma.a" ] ; then
  wget -c http://tukaani.org/xz/xz-5.2.3.tar.gz
  tar xf xz-5.2.3.tar.gz
  cd xz-5.2.3
  mkdir -p build/lib
  CFLAGS="-Wall $small_FLAGS" ./configure --prefix=$(pwd)/build --libdir=$(pwd)/build/lib --enable-static --disable-shared
  make -j$JOBS && make install
  cd -
fi

# Patch squashfuse_ll to be a library rather than an executable

cd squashfuse
if [ ! -e ./ll.c.orig ]; then
  patch -p1 --backup < ../squashfuse.patch
  patch -p1 --backup < ../squashfuse_dlopen.patch
fi
if [ ! -e ./squashfuse_dlopen.c ]; then
  cp ../squashfuse_dlopen.c .
fi
if [ ! -e ./squashfuse_dlopen.h ]; then
  cp ../squashfuse_dlopen.h .
fi

# Build libsquashfuse_ll library

if [ ! -e ./Makefile ] ; then
  export ACLOCAL_FLAGS="-I /usr/share/aclocal"
  libtoolize --force
  aclocal
  autoheader
  automake --force-missing --add-missing
  autoreconf -fi || true # Errors out, but the following succeeds then?
  autoconf
  sed -i '/PKG_CHECK_MODULES.*/,/,:./d' configure # https://github.com/vasi/squashfuse/issues/12
  CFLAGS="-Wall $small_FLAGS" ./configure --disable-demo --disable-high-level --without-lzo --without-lz4 --with-xz=$(pwd)/../xz-5.2.3/build

  # Patch Makefile to use static lzma
  sed -i "s|XZ_LIBS = -llzma  -L$(pwd)/../xz-5.2.3/build/lib|XZ_LIBS = -Bstatic -llzma  -L$(pwd)/../xz-5.2.3/build/lib|g" Makefile
fi

bash --version

make -j$JOBS

cd ..

# Build mksquashfs with -offset option to skip n bytes
# https://github.com/plougher/squashfs-tools/pull/13
cd squashfs-tools/squashfs-tools

# Patch squashfuse-tools Makefile to link against static llzma
sed -i "s|CFLAGS += -DXZ_SUPPORT|CFLAGS += -DXZ_SUPPORT -I../../xz-5.2.3/build/include|g" Makefile
sed -i "s|LIBS += -llzma|LIBS += -Bstatic -llzma  -L../../xz-5.2.3/build/lib|g" Makefile

make -j$JOBS XZ_SUPPORT=1 mksquashfs # LZ4_SUPPORT=1 did not build yet on CentOS 6
$STRIP mksquashfs

cd ../../

pwd

mkdir build
cd build

cp ../squashfs-tools/squashfs-tools/mksquashfs .

# Compile runtime but do not link

$CC -DVERSION_NUMBER=\"$(git describe --tags --always --abbrev=7)\" -I../squashfuse/ -D_FILE_OFFSET_BITS=64 -g $small_FLAGS -c ../runtime.c

# Prepare 1024 bytes of space for updateinformation
printf '\0%.0s' {0..1023} > 1024_blank_bytes

objcopy --add-section .upd_info=1024_blank_bytes \
        --set-section-flags .upd_info=noload,readonly runtime.o runtime2.o

objcopy --add-section .sha256_sig=1024_blank_bytes \
        --set-section-flags .sha256_sig=noload,readonly runtime2.o runtime3.o

# Now statically link against libsquashfuse_ll, libsquashfuse and liblzma
# and embed .upd_info and .sha256_sig sections
$CC $small_FLAGS $small_LDFLAGS -o runtime ../elf.c ../notify.c ../getsection.c runtime3.o \
    ../squashfuse/.libs/libsquashfuse_ll.a ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a \
    -L../xz-5.2.3/build/lib -Wl,-Bdynamic -lpthread -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic -ldl
$STRIP runtime

# Test if we can read it back
readelf -x .upd_info runtime # hexdump
readelf -p .upd_info runtime || true # string

# The raw updateinformation data can be read out manually like this:
HEXOFFSET=$(objdump -h runtime | grep .upd_info | awk '{print $6}')
HEXLENGTH=$(objdump -h runtime | grep .upd_info | awk '{print $3}')
dd bs=1 if=runtime skip=$(($(echo 0x$HEXOFFSET)+0)) count=$(($(echo 0x$HEXLENGTH)+0)) | xxd

# insert AppImage magic bytes
printf '\x41\x49\x02' | dd of=runtime bs=1 seek=8 count=3 conv=notrunc

# convert to embeddable file
bash build-embeddable-runtime.sh

# compile appimagetool but do not link - glib version
$CC -DVERSION_NUMBER=\"$(git describe --tags --always --abbrev=7)\" -D_FILE_OFFSET_BITS=64 -I../squashfuse/ \
    $(pkg-config --cflags glib-2.0) -g -Os ../getsection.c  -c ../appimagetool.c

# Now statically link against libsquashfuse - glib version
if [ $STATIC_BUILD -eq 1 ]; then
  # statically link against liblzma
  $CC -o appimagetool runtime-embed.c appimagetool.o ../elf.c ../getsection.c -DENABLE_BINRELOC ../binreloc.c \
    ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a \
    -L../xz-5.2.3/build/lib \
    -Wl,-Bdynamic -ldl -lpthread \
    -Wl,--as-needed $(pkg-config --cflags --libs glib-2.0) -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic
else
  # dinamically link against distro provided liblzma
  $CC -o appimagetool runtime-embed.c appimagetool.o ../elf.c ../getsection.c -DENABLE_BINRELOC ../binreloc.c \
    ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a \
    -Wl,-Bdynamic -ldl -lpthread \
    -Wl,--as-needed $(pkg-config --cflags --libs glib-2.0) -lz -llzma
fi

# Version without glib
# cc -D_FILE_OFFSET_BITS=64 -I ../squashfuse -I/usr/lib/x86_64-linux-gnu/glib-2.0/include -g -Os -c ../appimagetoolnoglib.c
# cc runtime-embed.c appimagetoolnoglib.o -DENABLE_BINRELOC ../binreloc.c ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a -Wl,-Bdynamic -ldl -lpthread -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic -o appimagetoolnoglib

# Compile and link digest tool

if [ $STATIC_BUILD -eq 1 ]; then
  $CC -o digest ../getsection.c ../digest.c -I../openssl-1.1.0c/build/include -L../openssl-1.1.0c/build/lib \
    -Wl,-Bstatic -lssl -lcrypto -Wl,-Bdynamic -lz -ldl
else
  $CC -o digest ../getsection.c ../digest.c -Wl,-Bdynamic -lssl -lcrypto -lz -ldl
fi

$STRIP digest

# Compile and link validate tool

if [ $STATIC_BUILD -eq 1 ]; then
  $CC -o validate ../getsection.c ../validate.c -I../openssl-1.1.0c/build/include -L../openssl-1.1.0c/build/lib \
    -Wl,-Bstatic -lssl -lcrypto -Wl,-Bdynamic -Wl,--as-needed $(pkg-config --cflags --libs glib-2.0) -lz -ldl
else
  $CC -o validate ../getsection.c ../validate.c -Wl,-Bdynamic -lssl -lcrypto \
    -Wl,--as-needed $(pkg-config --cflags --libs glib-2.0) -lz -ldl
fi

$STRIP validate

# AppRun
$CC $small_FLAGS $small_LDFLAGS ../AppRun.c -o AppRun

# check for libarchive name
have_libarchive3=0
archive_n=
if printf "#include <archive3.h>\nint main(){return 0;}" | cc -w -O0 -xc - -Wl,--no-as-needed -larchive3 2>/dev/null ; then
  have_libarchive3=1
  archive_n=3
fi
rm -f a.out

# appimaged, an optional component
if [ $STATIC_BUILD -eq 1 ]; then
  $CC -std=gnu99 -o appimaged -I../squashfuse/ ../getsection.c ../notify.c ../elf.c ../appimaged.c \
    -D_FILE_OFFSET_BITS=64 -DHAVE_LIBARCHIVE3=$have_libarchive3 -DVERSION_NUMBER=\"$(git describe --tags --always --abbrev=7)\" \
    ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a \
    -L../xz-5.2.3/build/lib -I../inotify-tools-3.14/build/include -L../inotify-tools-3.14/build/lib \
    -Wl,-Bstatic -linotifytools -Wl,-Bdynamic -larchive${archive_n} \
    -Wl,--as-needed \
    $(pkg-config --cflags --libs glib-2.0) \
    $(pkg-config --cflags --libs gio-2.0) \
    $(pkg-config --cflags --libs cairo) \
    -ldl -lpthread -lz -Wl,-Bstatic -llzma -Wl,-Bdynamic
else
  $CC -std=gnu99 -o appimaged -I../squashfuse/ ../getsection.c ../notify.c ../elf.c ../appimaged.c \
    -D_FILE_OFFSET_BITS=64 -DHAVE_LIBARCHIVE3=$have_libarchive3 -DVERSION_NUMBER=\"$(git describe --tags --always --abbrev=7)\" \
    ../squashfuse/.libs/libsquashfuse.a ../squashfuse/.libs/libfuseprivate.a \
    -Wl,-Bdynamic -linotifytools -larchive${archive_n} \
    -Wl,--as-needed \
    $(pkg-config --cflags --libs glib-2.0) \
    $(pkg-config --cflags --libs gio-2.0) \
    $(pkg-config --cflags --libs cairo) \
    -ldl -lpthread -lz -llzma
fi

cd ..

# Strip and check size and dependencies

rm build/*.o build/1024_blank_bytes
$STRIP build/* 2>/dev/null
chmod a+x build/*
ls -lh build/*
for FILE in $(ls build/*) ; do
  echo "$FILE"
  ldd "$FILE" || true
done

bash -ex "$HERE/build-appdirs.sh"

ls -lh

mkdir -p out
cp -r build/* ./*.AppDir out/
