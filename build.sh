#!/usr/bin/env bash
set -ex

function build_newlib() {
    mkdir -p newlib_build_"$1"
    mkdir -p newlib_"$1"
    pushd newlib_build_"$1"

    local c_flags="-O2"
    if [[ "$1" != "v0" ]] ; then 
      c_flags="${c_flags} -mcpu=$1"
    fi

    CFLAGS="${c_flags}" \
    CC="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/clang" \
      AR="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ar" \
      RANLIB="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ranlib" \
      ../newlib/newlib/configure --target=tbf-trezoa-trezoa --host=tbf-trezoa --build="${HOST_TRIPLE}" --prefix="${OUT_DIR}/newlib_$1"
    make install
    popd
}

function copy_newlib() {
    local folder_name=""
    if [[ "$1" != "v0" ]] ; then
        folder_name="$1"
    fi

    mkdir -p deploy/llvm/lib/tbpf"${folder_name}"
    mkdir -p deploy/llvm/tbpf"${folder_name}"
    cp -R newlib_"$1"/tbf-trezoa/lib/lib{c,m}.a deploy/llvm/lib/tbpf"${folder_name}"/
    cp -R newlib_"$1"/tbf-trezoa/include deploy/llvm/tbpf"${folder_name}"/    
}

unameOut="$(uname -s)"
case "${unameOut}" in
    Darwin*)
        EXE_SUFFIX=
        if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
            HOST_TRIPLE=aarch64-apple-darwin
            ARTIFACT=platform-tools-osx-aarch64.tar.bz2
        else
            HOST_TRIPLE=x86_64-apple-darwin
            ARTIFACT=platform-tools-osx-x86_64.tar.bz2
        fi;;
    MINGW*)
        EXE_SUFFIX=.exe
        HOST_TRIPLE=x86_64-pc-windows-msvc
        ARTIFACT=platform-tools-windows-x86_64.tar.bz2;;
    Linux* | *)
        EXE_SUFFIX=
        if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
            HOST_TRIPLE=aarch64-unknown-linux-gnu
            ARTIFACT=platform-tools-linux-aarch64.tar.bz2
        else
            HOST_TRIPLE=x86_64-unknown-linux-gnu
            ARTIFACT=platform-tools-linux-x86_64.tar.bz2
        fi
esac

cd "$(dirname "$0")"
OUT_DIR="$(realpath ./)/${1:-out}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
pushd "${OUT_DIR}"

git clone --single-branch --branch trezoa-tools-v1.52.4 https://github.com/trezoa-xyz/rust.git
echo "$( cd rust && git rev-parse HEAD )  https://github.com/trezoa-xyz/rust.git" >> version.md
# Set up submodules manually: clone llvm by branch name to avoid GitHub rejecting
# direct SHA fetches (GitHub upload-pack rejects "git fetch --depth 1 <sha>").
pushd rust
git submodule init
# Mark llvm-trezoa as update=none so "git submodule update" skips it entirely;
# we clone it manually by branch ref below.
git config submodule.src/llvm-trezoa.update none
# Shallow-clone llvm by branch ref (not SHA) -- GitHub serves this fine
git clone --single-branch --branch trezoa-rustc/20.1-2025-02-13 --depth 1 \
    https://github.com/trezoa-labs/llvm-project.git src/llvm-trezoa
# Update all other submodules with shallow clones (llvm is skipped via update=none)
git submodule update --init --depth 1 --jobs 8
popd

git clone --single-branch --branch trezoa-tools-v1.52 https://github.com/trezoa-xyz/cargo.git
echo "$( cd cargo && git rev-parse HEAD )  https://github.com/trezoa-xyz/cargo.git" >> version.md

pushd rust
if [[ "${HOST_TRIPLE}" == "x86_64-pc-windows-msvc" ]] ; then
    # Do not build lldb on Windows
    sed -i -e 's#enable-projects = \"clang;lld;lldb\"#enable-projects = \"clang;lld\"#g' bootstrap.toml
fi

if [[ "${HOST_TRIPLE}" == *"apple"* ]]; then
    ./src/llvm-trezoa/lldb/scripts/macos-setup-codesign.sh
fi

./build.sh
popd

pushd cargo
if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" ]] ; then
    OPENSSL_STATIC=1 OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu OPENSSL_INCLUDE_DIR=/usr/include/openssl cargo build --release
else
    OPENSSL_STATIC=1 cargo build --release
fi
popd

if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    git clone --single-branch --branch trezoa-tools-v1.52 https://github.com/trezoa-xyz/newlib.git
    echo "$( cd newlib && git rev-parse HEAD )  https://github.com/trezoa-xyz/newlib.git" >> version.md

    # Teach newlib's config.sub about Trezoa's intentional tbf target CPU.
    # The Rust/LLVM toolchain targets tbf-trezoa-trezoa, but upstream config.sub
    # only recognizes the legacy sbf CPU, so configure rejects tbf-* triples.
    # Mirror the existing sbf entries (perl is portable across Linux/macOS runners).
    find newlib -name config.sub -print0 | while IFS= read -r -d '' cs; do
        if ! grep -q "tbf | tbfel | tbfeb" "$cs"; then
            perl -pi -e 's/\| sbf \| sbfel \| sbfeb \|/| sbf | sbfel | sbfeb | tbf | tbfel | tbfeb |/' "$cs"
        fi
    done

    # Teach newlib's configure.host about Trezoa's intentional tbf CPU.
    # The rebrand renamed libc/machine/sbf -> libc/machine/tbf, but configure.host
    # still only matches sbf* and maps machine_dir=sbf (a directory that no longer
    # exists), so a tbf host_cpu falls through to the "Newlib does not support CPU"
    # default arm. Mirror the existing sbf arms for tbf, pointing at machine_dir=tbf
    # and --target=tbf-trezoa-trezoa. Perl is portable across Linux/macOS runners.
    find newlib -name configure.host -print0 | while IFS= read -r -d '' ch; do
        if ! grep -q "tbf\*)" "$ch"; then
            perl -0pi -e 's{^(  sbf\*\)\n\tmachine_dir=sbf\n\tnewlib_cflags="\$\{newlib_cflags\}[^\n]*--target=sbf-trezoa-trezoa"\n\t;;\n)}{$1  tbf*)\n\tmachine_dir=tbf\n\tnewlib_cflags="\$\{newlib_cflags\} -D_LDBL_EQ_DBL=1 -D__GLIBC_USE\\(...\\)=0 -D_trezoa_SOURCE -D_COMPILING_NEWLIB --target=tbf-trezoa-trezoa"\n\t;;\n}m' "$ch"
            perl -0pi -e 's{^(  sbf\*-\*-\*\)\n\tmachine_dir=sbf\n\tnewlib_cflags="\$\{newlib_cflags\} --target=sbf-trezoa-trezoa"\n\t;;\n)}{$1  tbf*-*-*)\n\tmachine_dir=tbf\n\tnewlib_cflags="\$\{newlib_cflags\} --target=tbf-trezoa-trezoa"\n\t;;\n}m' "$ch"
            perl -0pi -e 's{^(  sbf\*-\*-\*\)\n\tsyscall_dir=syscalls\n\t;;\n)}{$1  tbf*-*-*)\n\tsyscall_dir=syscalls\n\t;;\n}m' "$ch"
        fi
    done

    # Fix newlib raise() prototype conflict.
    # chk_fail.c, stack_protector.c and stdlib/arc4random.h carry a stale
    # "void raise(int);" forward declaration (added by the SOL-era rebrand) that
    # conflicts with <signal.h>'s "int raise (int);" (all three already include
    # <signal.h>), breaking the SSP and stdlib compiles. Align the prototype to the
    # header. The match is anchored and naturally idempotent (no match once it
    # already reads "int raise(int);").
    find newlib \( -path '*/libc/ssp/chk_fail.c' -o -path '*/libc/ssp/stack_protector.c' -o -path '*/libc/stdlib/arc4random.h' \) -print0 | while IFS= read -r -d '' f; do
        perl -pi -e 's/^void raise\(int\);$/int raise(int);/' "$f"
    done

    # Fix newlib libm/common/acosl.c forward declaration of acos().
    # Under _LDBL_EQ_DBL the SOL-era rebrand inserted a bogus "long double
    # acos(long double);" forward declaration with the wrong type. Simply
    # deleting it is not enough: -D_trezoa_SOURCE enables _REENT_ONLY, under
    # which <math.h> no longer declares "double acos (double);", so the bare
    # "return acos(x);" hits -Wimplicit-function-declaration (ISO C99 error).
    # Replace the bogus declaration with the correct one matching <math.h>:102
    # ("double acos (double);"). The match is anchored and idempotent.
    find newlib -path '*/libm/common/acosl.c' -print0 | while IFS= read -r -d '' f; do
        perl -0pi -e 's/^long double acos\(long double\);$/double acos(double);/m' "$f"
    done

    # Fix newlib libm/common/log2l.c macro-colliding forward declaration.
    # Under _LDBL_EQ_DBL the SOL-era rebrand inserted "double log2(double);",
    # but <math.h> defines log2 as a function-like macro
    # (#define log2(x) (log (x) / _M_LN2)). The preprocessor expands the bogus
    # prototype into "double (log (double) / _M_LN2);", failing with
    # "error: expected ')'" and aborting the libm/common compile. <math.h>
    # already provides log2, so the line is removed (log2l()'s "return log2(x);"
    # keeps using the macro). Anchored and naturally idempotent.
    find newlib -path '*/libm/common/log2l.c' -print0 | while IFS= read -r -d '' f; do
        perl -0pi -e 's/^double log2\(double\);\n//m' "$f"
    done

    # Fix newlib libc/time/strptime.c stale feature-macro guard.
    # The SOL-era rebrand renamed the feature macro to _trezoa_SOURCE in
    # sys/features.h (which then defines _REENT_ONLY, disabling the public
    # "errno" macro in sys/errno.h), but strptime.c still guards its body with
    # the old "#ifndef _SOLANA_SOURCE". Since the build defines _trezoa_SOURCE
    # (not _SOLANA_SOURCE), the body is compiled when it should be excluded for
    # Trezoa, and its bare "errno" uses fail ("use of undeclared identifier
    # 'errno'"). Rename the stale guard to _trezoa_SOURCE so the file is
    # excluded as intended. Word-boundary anchored and naturally idempotent.
    find newlib -path '*/libc/time/strptime.c' -print0 | while IFS= read -r -d '' f; do
        perl -pi -e 's/\b_SOLANA_SOURCE\b/_trezoa_SOURCE/g' "$f"
    done

    build_newlib "v0"
    build_newlib "v1"
    build_newlib "v2"
fi

# Copy rust build products
mkdir -p deploy/rust
cp version.md deploy/
cp -R "rust/build/${HOST_TRIPLE}/stage1/bin" deploy/rust/
cp -R "cargo/target/release/cargo${EXE_SUFFIX}" deploy/rust/bin/
mkdir -p deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/${HOST_TRIPLE}" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbf-trezoa-trezoa" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpf-trezoa-trezoa" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpfv1-trezoa-trezoa" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpfv2-trezoa-trezoa" deploy/rust/lib/rustlib/
find . -maxdepth 6 -type f -path "./rust/build/${HOST_TRIPLE}/stage1/lib/*" -exec cp {} deploy/rust/lib \;
mkdir -p deploy/rust/lib/rustlib/src/rust
cp "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/Cargo.lock" deploy/rust/lib/rustlib/src/rust
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/library" deploy/rust/lib/rustlib/src/rust

# Copy llvm build products
mkdir -p deploy/llvm/{bin,lib}
while IFS= read -r f
do
    bin_file="rust/build/${HOST_TRIPLE}/llvm/build/bin/${f}${EXE_SUFFIX}"
    if [[ -f "$bin_file" ]] ; then
        cp -R "$bin_file" deploy/llvm/bin/
    fi
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
clang-20
ld.lld
ld64.lld
llc
lld
lld-link
lldb
lldb-vscode
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
EOF
         )
cp -R "rust/build/${HOST_TRIPLE}/llvm/build/lib/clang" deploy/llvm/lib/
if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    cp -R newlib_v0/tbf-trezoa/lib/lib{c,m}.a deploy/llvm/lib/
    cp -R newlib_v0/tbf-trezoa/include deploy/llvm/
    
    copy_newlib "v0"
    copy_newlib "v1"
    copy_newlib "v2"

    cp -R rust/src/llvm-trezoa/lldb/scripts/trezoa/* deploy/llvm/bin/
    cp -R rust/build/${HOST_TRIPLE}/llvm/lib/liblldb.* deploy/llvm/lib/
    if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" || "${HOST_TRIPLE}" == "aarch64-unknown-linux-gnu" ]]; then
        cp -R rust/build/${HOST_TRIPLE}/llvm/local/lib/python* deploy/llvm/lib
    else
        cp -R rust/build/${HOST_TRIPLE}/llvm/lib/python* deploy/llvm/lib/
    fi
fi

# Check the Rust binaries
while IFS= read -r f
do
    "./deploy/rust/bin/${f}${EXE_SUFFIX}" --version
done < <(cat <<EOF
cargo
rustc
rustdoc
EOF
         )
# Check the LLVM binaries
while IFS= read -r f
do
    if [[ -f "./deploy/llvm/bin/${f}${EXE_SUFFIX}" ]] ; then
        "./deploy/llvm/bin/${f}${EXE_SUFFIX}" --version
    fi
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
ld.lld
llc
lld-link
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
trezoa-lldb
EOF
         )

tar -C deploy -jcf ${ARTIFACT} .
rm -rf deploy

popd

mv "${OUT_DIR}/${ARTIFACT}" .

# Build linux binaries on macOS in docker
if [[ "$(uname)" == "Darwin" ]] && [[ $# == 1 ]] && [[ "$1" == "--docker" ]] ; then
    docker system prune -a -f
    docker build -t trezoateam/platform-tools .
    id=$(docker create trezoateam/platform-tools /build.sh "${OUT_DIR}")
    docker cp build.sh "${id}:/"
    docker start -a "${id}"
    docker cp "${id}:${OUT_DIR}/trezoa-tbf-tools-linux-x86_64.tar.bz2" "${OUT_DIR}"
fi

