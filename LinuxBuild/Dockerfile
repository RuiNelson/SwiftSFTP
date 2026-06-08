FROM swift:6.2.0-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

ENTRYPOINT ["swift"]
CMD ["build", "--scratch-path", "/tmp/swift-build"]
