ARG BASE_IMAGE=ubuntu:22.04

ARG BAMBI_VERSION="0.17.1"
ARG BIOBAMBAM2_VERSION="2.0.185-release-20221211202123"
ARG BWA_VERSION="0.7.18"
ARG DEFLATE_VERSION="1.20"
ARG HTSLIB_VERSION="1.20"
ARG LIBMAUS2_VERSION="2.0.813-release-20221210220409"
ARG NPG_SEQ_COMMON_VERSION="51.1"
ARG SAMTOOLS_VERSION="1.20"
ARG TEEPOT_VERSION="1.2.0"

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

ARG LIBMAUS2_VERSION
RUN curl -sSL -O "https://gitlab.com/german.tischler/libmaus2/-/archive/${LIBMAUS2_VERSION}/libmaus2-${LIBMAUS2_VERSION}.tar.bz2" && \
    tar xfj libmaus2-${LIBMAUS2_VERSION}.tar.bz2 && \
    cd libmaus2-${LIBMAUS2_VERSION} && \
    ./configure --prefix=/usr/local && \
    make -j $(nproc) install && \
    ldconfig

ARG BIOBAMBAM2_VERSION
RUN curl -sSL -O "https://gitlab.com/german.tischler/biobambam2/-/archive/${BIOBAMBAM2_VERSION}/biobambam2-${BIOBAMBAM2_VERSION}.tar.bz2" && \
    tar xfj biobambam2-${BIOBAMBAM2_VERSION}.tar.bz2 && \
    cd biobambam2-${BIOBAMBAM2_VERSION} && \
    ./configure && \
    make -j $(nproc) install

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
    tar xzf v${BWA_VERSION}.tar.gz && \
    cd bwa-${BWA_VERSION} && \
    make -j $(nproc) && \
    cp ./bwa /usr/local/bin/ && \
    chmod +x /usr/local/bin/bwa

ARG BAMBI_VERSION
RUN git clone --single-branch --branch="$BAMBI_VERSION" --depth=1 "https://github.com/wtsi-npg/bambi.git" && \
    cd bambi && \
    autoreconf -fi && \
    ./configure && \
    make -j $(nproc) install

ARG NPG_SEQ_COMMON_VERSION
RUN git clone --single-branch --branch="$NPG_SEQ_COMMON_VERSION" --depth=1 "https://github.com/wtsi-npg/npg_seq_common.git" && \
    cd npg_seq_common && \
    cp ./bin/seqchksum_merge.pl /usr/local/bin/ && \
    chmod +x /usr/local/bin/seqchksum_merge.pl

RUN cpanm --notest --local-lib /usr/local/lib Module::Build

COPY . ./p4

RUN cd p4 && \
    cpanm --notest --local-lib /usr/local/lib --installdeps . && \
    cpanm --notest --local-lib /usr/local/lib .


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
        libcurl4 \
        liblzma5 \
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

ARG USER=p4user
ARG UID=1000
ARG GID=$UID

RUN groupadd --gid $GID $USER && \
    useradd --uid $UID --gid $GID --shell /bin/bash --create-home $USER

USER $USER

ENTRYPOINT []

CMD ["/bin/bash"]
