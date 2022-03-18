# docker-mediawiki-tools

Tools to support docker image creation for docker-mediawiki.

# Snippets

## Add tools to image

Dockerfile:
```
# add /build-tools and /tools
RUN curl -LJ https://github.com/gesinn-it-pub/docker-mediawiki-tools/tarball/Init -o /tools.tgz && \
    tar -xzf /tools.tgz -C / --strip-components 1 && rm /tools.tgz
# override by custom tools
COPY tools /tools
RUN chmod +x /build-tools/* /tools/*
ENV PATH="/tools:/build-tools:${PATH}"
```

## Override startup

./tools/startup-container.sh:
```
#!/bin/bash

set -euxo pipefail

service cron start
initialize-wiki.sh
apache2-foreground
```
