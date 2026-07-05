FROM postgres:16.13-alpine

ARG PGVECTOR_VERSION=0.8.0

# pgvector does not need optional LLVM bitcode for this local contract image.
RUN apk add --no-cache --virtual .build-deps \
        build-base \
        ca-certificates \
        git \
    && git clone --branch "v${PGVECTOR_VERSION}" --depth 1 \
        https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && make -C /tmp/pgvector PG_CONFIG=/usr/local/bin/pg_config OPTFLAGS="" with_llvm=no \
    && make -C /tmp/pgvector PG_CONFIG=/usr/local/bin/pg_config install with_llvm=no \
    && rm -rf /tmp/pgvector \
    && apk del .build-deps
