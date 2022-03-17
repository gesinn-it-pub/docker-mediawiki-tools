# docker-mediawiki-tools

Tools to support docker image creation for docker-mediawiki.

Dockerfile snippet:
```
# add /build-tools and / tools
RUN curl -LJ https://github.com/gesinn-it-pub/docker-mediawiki-tools/tarball/1.0.0 -o /tools.tgz && \
    tar -xzf /tools.tgz -C / --strip-components 1 && rm /tools.tgz && chmod +x /build-tools/* /tools/*
ENV PATH="/tools:/build-tools:${PATH}"
```
