FROM swift:6.3.0-noble

RUN apt-get update -q \
    && apt-get install -y --no-install-recommends zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

ENTRYPOINT ["swift"]
CMD ["build", "--scratch-path", "/tmp/swift-build"]
