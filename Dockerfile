FROM debian:12.5-slim

ARG XLSYNTH_VERSION=v0.0.181
ENV XLSYNTH_VERSION=${XLSYNTH_VERSION}

ARG XLSYNTH_DRIVER_VERSION=0.0.137
ENV XLSYNTH_DRIVER_VERSION=${XLSYNTH_DRIVER_VERSION}

# Install dependencies: python3, pip, wget
RUN apt-get update && \
    apt-get install -y python3 python3-pip python3-requests wget

# Install Rust and Cargo nightly via rustup along with OpenSSL and pkg-config
RUN apt-get install -y curl build-essential libssl-dev pkg-config && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly

# Download the download_release.py script
RUN wget -O download_release.py https://raw.githubusercontent.com/xlsynth/xlsynth-crate/refs/heads/main/download_release.py

# Execute the script to download the release with specified parameters.
#
# We use the version built on the rocky8 platform because it has
# the fewest exotic requirements for us to install here.
RUN python3 download_release.py -p rocky8 -v ${XLSYNTH_VERSION} -o ${XLSYNTH_VERSION} --dso --binaries dslx_interpreter_main,prove_quickcheck_main

# For debug use: look at what binaries are present in the versioned release download dir.
RUN ls -l ${XLSYNTH_VERSION}

# For debug use: look at what the shared library deps are.
RUN ldd ${XLSYNTH_VERSION}/libxls-rocky8.so

# For debug use: print out the GLIBC version dependencies for the shared library.
RUN strings ${XLSYNTH_VERSION}/libxls-rocky8.so 2>&1 | grep 'GLIBC' | grep "\."

# Tell the OS a new library is there.
RUN ldconfig

# Make a symlink dir called "latest" which has the version we downloaded.
RUN ln -s ${XLSYNTH_VERSION} latest

# Verify that the binary works by checking its version.
RUN latest/dslx_interpreter_main --version

# Just export this env var because it's commonly used in XLS stuff.
ENV XLSYNTH_TOOLS=latest/

# Add Cargo's bin directory to the PATH
ENV PATH="/root/.cargo/bin:$PATH"

# Create a temporary Cargo project to pre-fetch the xlsynth-driver dependency with the with-boolector-system feature
RUN mkdir temp-fetch && \
    echo '[package]' > temp-fetch/Cargo.toml && \
    echo 'name = "temp-fetch"' >> temp-fetch/Cargo.toml && \
    echo 'version = "0.1.0"' >> temp-fetch/Cargo.toml && \
    echo 'edition = "2021"' >> temp-fetch/Cargo.toml && \
    echo '' >> temp-fetch/Cargo.toml && \
    echo '[dependencies]' >> temp-fetch/Cargo.toml && \
    echo "xlsynth-driver = { version = \"${XLSYNTH_DRIVER_VERSION}\", features = [\"with-boolector-system\"] }" >> temp-fetch/Cargo.toml && \
    mkdir -p temp-fetch/src && \
    echo "fn main() {}" > temp-fetch/src/main.rs && \
    cd temp-fetch && \
    cargo fetch && \
    cd .. && \
    rm -rf temp-fetch

# Set up env vars for the driver build.
ENV XLS_DSO_PATH=/${XLSYNTH_VERSION}/libxls-rocky8.so
ENV DSLX_STDLIB_PATH=/${XLSYNTH_VERSION}/xls/dslx/stdlib/
ENV LD_LIBRARY_PATH=/${XLSYNTH_VERSION}:$LD_LIBRARY_PATH

RUN ls -al /${XLSYNTH_VERSION}
RUN ls -al /${XLSYNTH_VERSION}/libxls-rocky8.so

RUN wget -O /usr/lib/libboolector.so https://github.com/xlsynth/boolector-build/releases/download/boolector-debian10-171b2783200bf9f7636f3e595587ee822a0a6d07/libboolector-debian10.so

# Install xlsynth-driver using Cargo.
# We pass the --network=none flag to cut off network access for the build.
# We pass --offline to use the pre-fetched dependencies and not query crates.io.
RUN --network=none cargo install xlsynth-driver --version ${XLSYNTH_DRIVER_VERSION} --offline --features with-boolector-system
#RUN apt-get install -y cmake
#RUN cargo install xlsynth-driver --version ${XLSYNTH_DRIVER_VERSION} --features with-boolector


# Verify that xlsynth-driver works by showing its version.
RUN xlsynth-driver version

# Place some sample DSLX code in a file.
RUN echo "import std;" > /tmp/my_add.x
RUN echo "const UNUSED = std::popcount(u3:0b111);" >> /tmp/my_add.x
RUN echo "fn f(x: u8) -> u8 { x + x - x }" >> /tmp/my_add.x
RUN echo "#[test] fn test_my_add() { assert_eq(f(u8::MAX), u8::MAX); }" >> /tmp/my_add.x
RUN echo "#[quickcheck] fn quickcheck_my_add(x: u8) -> bool { f(x) == x }" >> /tmp/my_add.x

# Run the DSLX interpreter to check the unit test and do concrete evaluation of the quickcheck.
RUN latest/dslx_interpreter_main /tmp/my_add.x --compare=jit --dslx_stdlib_path ${XLSYNTH_TOOLS}/xls/dslx/stdlib/
# Prove the quickcheck for all inputs.
RUN latest/prove_quickcheck_main /tmp/my_add.x --dslx_stdlib_path ${XLSYNTH_TOOLS}/xls/dslx/stdlib/

# Some of the functionality is nicely integrated into a unified "driver program".
# We can configure it centrally.

RUN echo "[toolchain]" > xlsynth-toolchain.toml
RUN echo "dslx_stdlib_path = \"${XLSYNTH_TOOLS}/xls/dslx/stdlib/\"" >> xlsynth-toolchain.toml

# Convert the DSLX code into IR.
RUN xlsynth-driver dslx2ir --dslx_input_file /tmp/my_add.x --dslx_top f > /tmp/my_add.ir
RUN cat /tmp/my_add.ir

# Optimize the IR.
RUN xlsynth-driver ir2opt /tmp/my_add.ir --top __my_add__f > /tmp/my_add.opt.ir
RUN cat /tmp/my_add.opt.ir

# Show the JSON output "summary stats" for the gate mapping.
RUN xlsynth-driver ir2gates /tmp/my_add.opt.ir --quiet=true

# Now do the above sequence to show how many gates are in the
# apfloat f32 adder.
RUN echo "import float32;" > /tmp/apfloat_f32_adder.x
RUN echo "type F32 = float32::F32;" >> /tmp/apfloat_f32_adder.x
RUN echo "fn my_f32_add(a: F32, b: F32) -> F32 { float32::add(a, b) }" >> /tmp/apfloat_f32_adder.x

# Convert the .x file to optimized IR.
RUN xlsynth-driver dslx2ir --dslx_input_file /tmp/apfloat_f32_adder.x --dslx_top my_f32_add --opt=true > /tmp/apfloat_f32_adder.opt.ir

# Show the JSON output "summary stats" for the gate mapping.
RUN xlsynth-driver ir2gates /tmp/apfloat_f32_adder.opt.ir --quiet=true

# -- IR equivalence example
RUN echo "package id_convoluted" > /tmp/id-convoluted.ir
RUN echo "fn id(x: bits[32] id=1) -> bits[32] {" >> /tmp/id-convoluted.ir
RUN echo "  y: bits[32] = add(x, x, id=2)" >> /tmp/id-convoluted.ir
RUN echo "  ret z: bits[32] = sub(y, x, id=3)" >> /tmp/id-convoluted.ir
RUN echo "}" >> /tmp/id-convoluted.ir

RUN echo "package id_simple" > /tmp/id-simple.ir
RUN echo "fn id(x: bits[32] id=1) -> bits[32] {" >> /tmp/id-simple.ir
RUN echo "  ret z: bits[32] = identity(x, id=2)" >> /tmp/id-simple.ir
RUN echo "}" >> /tmp/id-simple.ir

RUN xlsynth-driver ir-equiv --boolector=true /tmp/id-convoluted.ir /tmp/id-simple.ir --top id > /tmp/id-equiv.txt
RUN cat /tmp/id-equiv.txt

CMD ["bash"]
