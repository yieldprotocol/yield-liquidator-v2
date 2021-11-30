FROM amazonlinux:latest AS builder
# install OS deps
RUN yum install gcc openssl-devel -y
# install rust compiler
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# build dependencies - they're not changed frequently
WORKDIR /usr/src/
COPY Cargo.* ./
COPY Cargo.toml .
RUN mkdir -p src/bin \
    && echo "//" > src/lib.rs \
    && echo "fn main() {}" > src/bin/liquidator.rs \
    && ~/.cargo/bin/cargo build --release

# copy sources and build
COPY abis abis
COPY build.rs .
COPY src src

RUN ~/.cargo/bin/cargo build --release

FROM amazonlinux:latest AS liquidator
COPY --from=builder /usr/src/target/release/liquidator /usr/bin
COPY aws/liquidator.sh /usr/bin

CMD ["/usr/bin/liquidator.sh"]
