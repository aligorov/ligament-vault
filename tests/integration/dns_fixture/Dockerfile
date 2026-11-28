FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    age ca-certificates curl dnsmasq-base openssh-client python3 socat util-linux \
    && rm -rf /var/lib/apt/lists/*
