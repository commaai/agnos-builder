#!/bin/bash -e

# Install rustup
curl https://sh.rustup.rs -sSf | bash -s -- -y
export PATH="/root/.cargo/bin:$PATH"

# Install cargo-deb
cargo install cargo-deb

# Package rep-grep
cd /tmp
git clone https://github.com/robenkleene/rep-grep.git
cd rep-grep
cargo deb
mv target/debian/rep-grep*.deb /tmp/rep-grep.deb

# Package ren-find
cd /tmp
git clone https://github.com/robenkleene/ren-find.git
cd ren-find
cargo deb
mv target/debian/ren-find*.deb /tmp/ren-find.deb
