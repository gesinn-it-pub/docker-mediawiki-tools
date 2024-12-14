ARG MEDIAWIKI_VERSION=1.39
FROM gesinn/docker-mediawiki-sqlite:${MEDIAWIKI_VERSION}

RUN rm -rf LocalSettings.php /var/www/data

COPY tools /tools
COPY build-tools /build-tools
RUN chmod +x /build-tools/* /tools/*
ENV PATH="/tools:/build-tools:${PATH}"

CMD ["bash", "-c", "initialize-wiki.sh && startup-container.sh"]
