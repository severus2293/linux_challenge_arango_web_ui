ARG BUILD_IMAGE=ubuntu:noble-20240827.1

# Stage 1: Prepare build image
FROM $BUILD_IMAGE as builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PACKAGES_DEBIAN=" \
    build-essential \
    git-core \
    libssl-dev \
    libjemalloc-dev \
    cmake \
    python3 \
    libldap2-dev \
    pkg-config \
    systemd-dev \
    yarn \
    libxml2-dev \
    libsystemd-dev \
    libbrotli-dev \
    clang-16 \
    lld-16 \
    llvm-16 \
    python3-pyqt-distutils \
    python3-distutils-extra \
    libopenblas-dev \
    liblapack-dev \
    libomp-dev \
    zlib1g-dev \
    libreadline-dev \
    curl \
    jq \
    pwgen \
    numactl \
    elfutils \
    sysstat \
    ca-certificates \
    vim \
    lsof \
    ninja-build \
    libatomic1 \
"

RUN mkdir -p /src/
WORKDIR /src/

RUN apt update -qq -y && \
    apt upgrade -qq -y && \
    apt install -qq -y wget gnupg $PACKAGES_DEBIAN && \
    wget -qO- https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
    apt update -qq -y && \
    apt install -qq -y yarn && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# Stage 2: Build from sources
FROM builder as build

RUN mkdir -p /src/arangodb
WORKDIR /src/

# Копируем исходный код
ADD arangodb/ arangodb/

WORKDIR /src/arangodb/

# Указываем пути к BLAS/LAPACK
ENV BLAS_LIBRARIES=/usr/lib/x86_64-linux-gnu/libopenblas.so
ENV LAPACK_LIBRARIES=/usr/lib/x86_64-linux-gnu/liblapack.so
ENV CMAKE_PREFIX_PATH=/usr/lib/x86_64-linux-gnu

RUN mkdir -p build
WORKDIR /src/arangodb/build

# Настраиваем CMake с префиксом установки
RUN cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DPython_EXECUTABLE=/usr/bin/python \
    -DPython3_EXECUTABLE=/usr/bin/python3 \
    -DCMAKE_C_COMPILER=clang-16 \
    -DCMAKE_CXX_COMPILER=clang++-16 \
    -DCMAKE_C_COMPILER_AR=/usr/bin/llvm-ar-16 \
    -DCMAKE_CXX_COMPILER_AR=/usr/bin/llvm-ar-16 \
    -DCMAKE_C_COMPILER_RANLIB=/usr/bin/llvm-ranlib-16 \
    -DCMAKE_CXX_COMPILER_RANLIB=/usr/bin/llvm-ranlib-16 \
    -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld-16 \
    -DUSE_GOOGLE_TESTS=Off \
    -DVERBOSE=On \
    -DUSE_MAINTAINER_MODE=Off \
    -DUSE_JEMALLOC=On \
    -DUSE_V8=On \
    -DCMAKE_CXX_STANDARD=20 \
    -DOPENSSL_USE_STATIC_LIBS=OFF \
    -DUSE_RCLONE=On \
    -DMINIMAL_DEBUG_INFO=On \
    -DDEFAULT_ARCHITECTURE=sandybridge \
    -DUSE_ARM=On \
    -DOpenMP_C_FLAGS=-fopenmp \
    -DOpenMP_CXX_FLAGS=-fopenmp \
    -DOpenMP_C_LIB_NAMES=omp \
    -DOpenMP_CXX_LIB_NAMES=omp \
    -DOpenMP_omp_LIBRARY=/usr/lib/x86_64-linux-gnu/libomp.so \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_SYSCONFDIR=/etc \
    .. 2>&1 | tee /src/arangodb/build/cmake.log

# Компилируем
RUN make
RUN make install

# Stage 3: Final image
FROM ubuntu:noble-20240827.1

ENV DEBIAN_FRONTEND=noninteractive
ENV GLIBCXX_FORCE_NEW=1

# Устанавливаем runtime-зависимости
RUN apt update -qq -y && \
    apt install -qq -y \
    curl \
    jq \
    pwgen \
    numactl \
    elfutils \
    sysstat \
    ca-certificates \
    vim \
    lsof \
    libjemalloc-dev \
    libssl-dev \
    zlib1g-dev \
    libldap2-dev \
    libreadline-dev \
    libopenblas-dev \
    liblapack-dev \
    libomp-dev \
    libatomic1 \
    nodejs \
    && apt clean && \
    rm -rf /var/lib/apt/lists/*

# Копируем установленные файлы из /usr/local
COPY --from=build /usr/local /usr/local

# Копируем конфигурационные файлы из /etc/arangodb3, если они существуют
COPY --from=build /etc/arangodb3 /etc/arangodb3

# Резервное копирование arangod.conf из исходников, если /etc/arangodb3 пустое
COPY --from=build /src/arangodb/etc/relative/arangod.conf /etc/arangodb3/arangod.conf

# Проверяем содержимое /etc/arangodb3
RUN ls -l /etc/arangodb3 > /etc/arangodb3/contents.log || true

# Создаём директории для данных
RUN mkdir -p /var/lib/arangodb3 /var/lib/arangodb3-apps

# Копируем и настраиваем entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Создаём пользователя и группу arangodb без домашней директории
RUN groupadd -r arangodb && useradd -r -g arangodb --no-create-home arangodb

# Устанавливаем временную зону (UTC)
RUN echo "UTC" > /etc/timezone

RUN mkdir -p /docker-entrypoint-initdb.d

COPY foxx-temp-db/ /foxx-temp-db/
RUN chown -R arangodb:arangodb /foxx-temp-db
    
# Настраиваем права доступа для OpenShift (GID 0)
RUN chown arangodb:arangodb /var/lib/arangodb3 /var/lib/arangodb3-apps /etc/arangodb3 && \
    chgrp 0 /var/lib/arangodb3 /var/lib/arangodb3-apps /etc/arangodb3 && \
    chmod 775 /var/lib/arangodb3 /var/lib/arangodb3-apps /etc/arangodb3

# Открываем порт
EXPOSE 8529

# Указываем entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Настраиваем healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=5 \
    CMD curl -f http://localhost:8529/_api/version || exit 1
