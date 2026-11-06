# syntax=docker/dockerfile:1
#
# Team Car on a server. Build from the teamcar directory:
#
#   docker build -f deploy/Dockerfile -t teamcar .
#   docker run -d --name teamcar --init -p 7420:7420 -v teamcar-data:/data teamcar
#
# Everything that must survive an upgrade lives in the /data volume: Team Car's database
# (TEAMCAR_HOME=/data/teamcar), repositories and worktrees, and the teamcar user's home
# (/data/home: claude, codex and gh logins, git config, SSH keys).

FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/teamcar ./cmd/teamcar

# Node.js for the agent CLIs: claude-code needs Node 22+, newer than Debian stable's.
FROM node:22-slim AS node

FROM debian:stable-slim
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
# git and ssh for repositories; bash for scripts; tini reaps orphans (processes whose parent
# exited are re-parented to PID 1, and Team Car doesn't reap strangers).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg less openssh-client procps tini \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* /root/.npm

RUN useradd --uid 1000 --user-group --home-dir /data/home --create-home --shell /bin/bash teamcar \
 && mkdir -p /data/teamcar /data/repos /data/workspaces \
 && chown -R teamcar:teamcar /data

COPY --from=build /out/teamcar /usr/local/bin/teamcar

ENV TEAMCAR_HOME=/data/teamcar \
    TEAMCAR_REPOS_ROOT=/data/repos \
    TEAMCAR_WORKSPACES_ROOT=/data/workspaces \
    HOME=/data/home
USER teamcar
WORKDIR /data/home
VOLUME /data
EXPOSE 7420

# A bind-mounted /data starts empty: create the home and state directories on the way in.
ENTRYPOINT ["/usr/bin/tini", "--", "/bin/sh", "-c", "mkdir -p \"$HOME\" \"$TEAMCAR_HOME\" && exec teamcar \"$@\"", "teamcar"]
# The Unix socket lets `docker exec teamcar teamcar ctl ...` work without a token.
CMD ["serve", "--listen", "tcp://0.0.0.0:7420", "--listen", "unix:///data/teamcar/teamcar.sock"]
