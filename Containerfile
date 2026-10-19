FROM debian:bookworm-slim

ARG APP_USER=imap-filter
ARG APP_UID=10001
ARG APP_GID=10001

ENV APP_USER=${APP_USER} \
	APP_UID=${APP_UID} \
	APP_GID=${APP_GID} \
	HOME=/home/${APP_USER}

ENV DEBIAN_FRONTEND=noninteractive

# Setup dedicated user
RUN groupadd --gid ${APP_GID} ${APP_USER}
RUN useradd --uid ${APP_UID} --gid ${APP_GID} --create-home --shell /bin/bash ${APP_USER}

# Install minimal toolchain: imapfilter, bogofilter, ca-certificates
RUN apt-get update && apt-get install -y --no-install-recommends \
	imapfilter \
	bogofilter \
	ca-certificates \
	bash \
	tzdata \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR ${HOME}

COPY --chown=${APP_USER}:${APP_USER} entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER ${APP_UID}:${APP_GID}

ENTRYPOINT ["/entrypoint.sh"]
