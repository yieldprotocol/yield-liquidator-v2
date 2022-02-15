### Image 1: rust builder
FROM amazonlinux:latest AS builder
## Step 0: install dependencies
RUN yum update -y
# install OS deps
RUN yum install gcc openssl-devel -y
# install rust compiler
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

## Step 1: build 'liquidator' binary
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

### Image 2: yarn builder
FROM amazonlinux:latest AS yarnbuilder
RUN yum update -y
# add nodejs repo
RUN curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
# install OS deps
RUN yum install nodejs git -y
# install yarn
RUN corepack enable

WORKDIR /usr/src/
COPY package.json tsconfig.json yarn.lock hardhat.config.ts ./
RUN yarn

COPY src src
COPY contracts contracts
COPY scripts scripts
RUN mkdir abis && yarn build
RUN npm run buildRouter

### Image 3: binaries
FROM amazonlinux:latest AS liquidator
COPY --from=builder /usr/src/target/release/liquidator /usr/bin
COPY --from=yarnbuilder /usr/src/build/bin/router /usr/bin
COPY aws/liquidator.sh /usr/bin

CMD ["/usr/bin/liquidator.sh"]
