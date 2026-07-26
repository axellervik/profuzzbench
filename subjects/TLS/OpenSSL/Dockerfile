FROM openssl-mabflnet-base

ENV WORKDIR="/home/ubuntu/experiments"

# Import environment variable to pass as parameter to make (e.g., to make parallel builds with -j)
ARG MAKE_OPT

# Build mabflnet (our fuzzer fork -- this layer is the only one that changes between iterations)
RUN git clone --branch mab https://github.com/axellervik/mabflnet.git mabflnet && \
    cd mabflnet && \
    make clean all $MAKE_OPT && \
    cd llvm_mode && make $MAKE_OPT

# Set up environment variables for mabflnet
ENV AFLNET="/home/ubuntu/mabflnet"
ENV PATH="${PATH}:${AFLNET}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_AFFINITY=1

COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
