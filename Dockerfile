# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# STAGE 1: Compiler (Builder)
# ---------------------------------------------------------------------------
FROM rust:bookworm AS compiler

# Builder dependencies only (apt.llvm.org repo tooling + native libs for
# bindgen/clang-sys). Lists cleaned in the same layer to keep it small.
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget gnupg lsb-release \
        libz-dev libedit-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Add the official LLVM apt repo (Bookworm, branch 22) and install ONLY the
# packages needed to build — no lldb, no clangd, no full "all" toolchain.
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-22 main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clang-22 libclang-22-dev llvm-22-dev \
    && rm -rf /var/lib/apt/lists/*

# Point clang-sys/bindgen-style crates at LLVM 22
ENV LLVM_SYS_220_PREFIX=/usr/lib/llvm-22 \
    LIBCLANG_PATH=/usr/lib/llvm-22/lib

# Preserve Cargo path while adding LLVM binaries
ENV PATH="/usr/local/cargo/bin:/usr/lib/llvm-22/bin:${PATH}"

# Persist PATH for interactive devcontainer shells (Zed/VS Code)
RUN echo 'export PATH="/usr/local/cargo/bin:/usr/lib/llvm-22/bin:${PATH}"' > /etc/profile.d/cargo.sh

WORKDIR /app

# --- Dependency caching layer ---------------------------------------------
# Copy manifests first, create stub targets so `cargo fetch` can resolve the
# full dependency graph WITHOUT any real source code. Dependency downloads
# are then cached as long as Cargo.toml/Cargo.lock don't change.
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN set -e; \
    for d in crates/*/; do \
        mkdir -p "${d}src"; \
        if [ ! -f "${d}src/lib.rs" ]; then touch "${d}src/lib.rs"; fi; \
    done; \
    if [ ! -f src/main.rs ]; then mkdir -p src && touch src/main.rs; fi; \
    cargo fetch && rm -rf crates src

# --- Real sources -----------------------------------------------------------
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY crates ./crates

# Build with BuildKit cache mounts: registry + git checkouts + target dir
# survive across builds without bloating image layers.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release \
    && cp /app/target/release/genpay /tmp/genpay   # copy OUT of the cache mount

# ---------------------------------------------------------------------------
# STAGE 2: Development (devcontainers / CI with full toolchain)
# ---------------------------------------------------------------------------
FROM compiler AS dev
WORKDIR /workspaces/genpay
# No ENTRYPOINT: Zed/VS Code need to exec their own probes and shells.
# sleep infinity keeps the container running so `docker exec` works.
CMD ["sleep", "infinity"]

# ---------------------------------------------------------------------------
# STAGE 3: Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Runtime libs + root certs. libstdc++6 covers transitive C++ deps from
# LLVM-linked crates; drop it if `ldd` shows it's unneeded.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libedit2 libz1 libxml2 libstdc++6 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m appuser

COPY --from=compiler /tmp/genpay /usr/local/bin/genpay

# /src must be writable by the non-root user
RUN mkdir -p /src && chown appuser:appuser /src

USER appuser
WORKDIR /src
ENTRYPOINT ["/usr/local/bin/genpay"]
