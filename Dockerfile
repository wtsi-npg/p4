ARG BASE_IMAGE=ubuntu:22.04

ARG BAMBI_VERSION="0.18.0"
ARG BIOBAMBAM2_VERSION="2.0.185-release-20221211202123"
ARG BWA_VERSION="0.7.17"
ARG BWA_MEM2_VERSION="2.2.1"
ARG DEFLATE_VERSION="1.20"
ARG HTSLIB_VERSION="1.21"
ARG IO_LIB_VERSION="1.15.0"
ARG LIBMAUS2_VERSION="2.0.813-release-20221210220409"
ARG NPG_SEQ_COMMON_VERSION="51.1"
ARG SAMTOOLS_VERSION="1.21"
ARG TEEPOT_VERSION="1.2.0"
ARG PCAP_CORE_VERSION="5.7.0"

FROM $BASE_IMAGE as build

WORKDIR /tmp

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get install -q -y --no-install-recommends \
    apt-utils \
    ca-certificates \
    curl \
    dirmngr \
    gpg \
    gpg-agent \
    lsb-release \
    locales && \
    locale-gen en_GB en_GB.UTF-8 && \
    localedef -i en_GB -c -f UTF-8 -A /usr/share/locale/locale.alias en_GB.UTF-8

ENV LANG=en_GB.UTF-8 \
    LANGUAGE=en_GB \
    LC_ALL=en_GB.UTF-8

# Build tools
RUN apt-get update && \
    apt-get install -q -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    cmake \
    gcc \
    git \
    libtool \
    make \
    perl \
    pkg-config \
    unattended-upgrades

# OS build dependencies
RUN apt-get install -q -y --no-install-recommends \
    cpanminus \
    libboost-dev \
    libbz2-dev \
    libcurl4-gnutls-dev  \
    liblzma-dev \
    libssl-dev \
    libxml2-dev \
    nettle-dev \
    zlib1g-dev

RUN unattended-upgrade -v

ARG DEFLATE_VERSION
RUN curl -sSL -O https://github.com/ebiggers/libdeflate/releases/download/v${DEFLATE_VERSION}/libdeflate-${DEFLATE_VERSION}.tar.gz && \
    tar xzf libdeflate-${DEFLATE_VERSION}.tar.gz && \
    cd libdeflate-${DEFLATE_VERSION} && \
    cmake -DCMAKE_BUILD_TYPE=Release -S . -B ./build && \
    cmake --build ./build && \
    cd ./build && \
    make -j $(nproc) install && \
    ldconfig

ARG IO_LIB_VERSION
RUN SLUG=$(echo ${IO_LIB_VERSION} | tr '.' '-') && \
    curl -sSL -O https://github.com/jkbonfield/io_lib/releases/download/io_lib-${SLUG}/io_lib-${IO_LIB_VERSION}.tar.gz && \
    tar xzf io_lib-${IO_LIB_VERSION}.tar.gz && \
    cd io_lib-${IO_LIB_VERSION} && \
    ./configure --with-libdeflate && \
    make -j $(nproc) install && \
    ldconfig

ARG TEEPOT_VERSION
RUN curl -sSL -O "https://github.com/wtsi-npg/teepot/releases/download/${TEEPOT_VERSION}/teepot-${TEEPOT_VERSION}.tar.gz" && \
    tar xzf teepot-${TEEPOT_VERSION}.tar.gz && \
    cd teepot-${TEEPOT_VERSION} && \
    ./configure && \
    make -j $(nproc) install

ARG HTSLIB_VERSION
RUN curl -sSL -O "https://github.com/samtools/htslib/releases/download/${HTSLIB_VERSION}/htslib-${HTSLIB_VERSION}.tar.bz2" && \
    tar xfj htslib-${HTSLIB_VERSION}.tar.bz2 && \
    cd htslib-${HTSLIB_VERSION} && \
    ./configure --with-libdeflate --enable-libcurl --enable-s3 && \
    make -j $(nproc) install && \
    ldconfig

ARG SAMTOOLS_VERSION
RUN curl -sSL -O "https://github.com/samtools/samtools/releases/download/${SAMTOOLS_VERSION}/samtools-${SAMTOOLS_VERSION}.tar.bz2" && \
    tar xfj samtools-${SAMTOOLS_VERSION}.tar.bz2 && \
    cd samtools-${SAMTOOLS_VERSION} && \
    ./configure --with-htslib=system --without-curses && \
    make -j $(nproc) install

ARG BWA_VERSION
RUN curl -sSL -O "https://github.com/lh3/bwa/archive/refs/tags/v${BWA_VERSION}.tar.gz" && \
    tar xzvf ./v${BWA_VERSION}.tar.gz && \
    cd ./bwa-${BWA_VERSION} && \
    pwd && \
    make CC='gcc -fcommon' -j $(nproc) && \
    cp ./bwa /usr/local/bin/ && \
    chmod +x /usr/local/bin/bwa && \
    ln -s /usr/local/bin/bwa /usr/local/bin/bwa0_6

ARG BWA_MEM2_VERSION
RUN curl -sSL -O "https://github.com/bwa-mem2/bwa-mem2/releases/download/v${BWA_MEM2_VERSION}/bwa-mem2-${BWA_MEM2_VERSION}_x64-linux.tar.bz2" && \
    tar xfj ./bwa-mem2-${BWA_MEM2_VERSION}_x64-linux.tar.bz2 && \
    cd ./bwa-mem2-${BWA_MEM2_VERSION}_x64-linux && \
    cp ./bwa-mem2 /usr/local/bin/ && \
    cp ./bwa-mem2.avx /usr/local/bin/ && \
    cp ./bwa-mem2.avx2 /usr/local/bin/ && \
    cp ./bwa-mem2.avx512bw /usr/local/bin/ && \
    cp ./bwa-mem2.sse41 /usr/local/bin/ && \
    cp ./bwa-mem2.sse42 /usr/local/bin/

ARG BAMBI_VERSION
RUN git clone --single-branch --branch="$BAMBI_VERSION" --depth=1 "https://github.com/wtsi-npg/bambi.git" && \
    cd bambi && \
    autoreconf -fi && \
    ./configure && \
    make -j $(nproc) install

ARG LIBMAUS2_VERSION
RUN curl -sSL -O "https://gitlab.com/german.tischler/libmaus2/-/archive/${LIBMAUS2_VERSION}/libmaus2-${LIBMAUS2_VERSION}.tar.bz2" && \
    tar xfj libmaus2-${LIBMAUS2_VERSION}.tar.bz2 && \
    cd libmaus2-${LIBMAUS2_VERSION} && \
    ./configure --prefix=/usr/local --with-io_lib --with-nettle && \
    make -j $(nproc) install && \
    ldconfig

ARG BIOBAMBAM2_VERSION
RUN curl -sSL -O "https://gitlab.com/german.tischler/biobambam2/-/archive/${BIOBAMBAM2_VERSION}/biobambam2-${BIOBAMBAM2_VERSION}.tar.bz2" && \
    tar xfj biobambam2-${BIOBAMBAM2_VERSION}.tar.bz2 && \
    cd biobambam2-${BIOBAMBAM2_VERSION} && \
    ./configure && \
    make -j $(nproc) install

ARG PCAP_CORE_VERSION
RUN git clone --single-branch --branch="$PCAP_CORE_VERSION" --depth=1 "https://github.com/cancerit/PCAP-core.git" && \
    cd PCAP-core/c && \
    make -j $(nproc) ../bin/bam_stats CC=gcc CFLAGS='-O3 -g -DVERSION=\"${PCAP_CORE_VERSION}\"' && \
    cp ../bin/bam_stats /usr/local/bin/ && \
    chmod +x /usr/local/bin/bam_stats


ARG NPG_SEQ_COMMON_VERSION
RUN git clone --single-branch --branch="$NPG_SEQ_COMMON_VERSION" --depth=1 "https://github.com/wtsi-npg/npg_seq_common.git" && \
    cd npg_seq_common && \
    cp ./bin/seqchksum_merge.pl /usr/local/bin/ && \
    chmod +x /usr/local/bin/seqchksum_merge.pl

RUN cpanm --notest --local-lib /usr/local Module::Build

COPY . ./p4

RUN cd p4 && \
    cpanm --notest --local-lib /usr/local --installdeps . && \
    cpanm --notest --local-lib /usr/local .


FROM $BASE_IMAGE

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get install -q -y --no-install-recommends \
    apt-utils \
    ca-certificates \
    lsb-release \
    unattended-upgrades \
    locales && \
    locale-gen en_GB en_GB.UTF-8 && \
    localedef -i en_GB -c -f UTF-8 -A /usr/share/locale/locale.alias en_GB.UTF-8

ENV LANG=en_GB.UTF-8 \
    LANGUAGE=en_GB \
    LC_ALL=en_GB.UTF-8

RUN apt-get install -q -y --no-install-recommends \
        libboost-atomic1.74.0 \
        libbz2-1.0 \
        libcurl3-gnutls \
        libcurl4 \
        libgomp1 \
        liblzma5 \
        libnettle8 \
        libssl3 \
        libxml2 \
        zlib1g \
        perl && \
        unattended-upgrade -v && \
        apt-get remove -q -y unattended-upgrades && \
        apt-get autoremove -q -y && \
        apt-get clean -q -y && \
        rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local /usr/local

RUN ldconfig

ARG APP_USER=appuser
ARG APP_UID=1000
ARG APP_GID=$APP_UID

WORKDIR /app

RUN groupadd --gid $APP_GID $APP_USER && \
    useradd --uid $APP_UID --gid $APP_GID --shell /bin/bash --create-home $APP_USER

USER $APP_USER

ENTRYPOINT []

CMD ["/bin/bash"]
