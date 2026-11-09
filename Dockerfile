# Odoo 17/18/19 run on Python 3.10-3.12. For Odoo 16 or older, use 3.10.
ARG PYTHON_VERSION=3.12
FROM node:26-trixie AS node
FROM python:${PYTHON_VERSION}-trixie

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
        # C compiler and make, to build Python packages with C extensions
        build-essential \
        # PostgreSQL headers, for psycopg2
        libpq-dev \
        # LDAP and SASL headers, for python-ldap
        libldap2-dev \
        libsasl2-dev \
        # XML/XSLT headers, for lxml
        libxml2-dev \
        libxslt1-dev \
        # Image headers, for Pillow
        libjpeg-dev \
        zlib1g-dev \
        # Needed by cffi-based packages such as cryptography
        libffi-dev \
        postgresql-client \
        sudo \
        zsh \
        vim \
        # headless browser for Odoo's tour/HttpCase tests
        chromium \
        # free fonts so that text renders properly in chromium screenshots and
        # wkhtmltopdf PDFs
        fonts-liberation \
        cowsay \
        fortune-mod \
        fortunes \
        fortunes-debian-hints \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && npm install -g rtlcss

ARG TARGETARCH
RUN curl -fsSLo /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_${TARGETARCH}.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/*

# Non-root user with passwordless sudo
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/zsh ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

COPY dotfiles/zshrc /home/${USERNAME}/.zshrc
# Warns if VS Code forwards an SSH agent that holds keys (zshrc, postAttachCommand)
COPY dotfiles/check-ssh-agent.sh /usr/local/bin/check-ssh-agent
RUN echo "alias obin='/odoo/community/odoo-bin --addons-path=/odoo/community/addons,/odoo/enterprise'" >> /home/${USERNAME}/.zshrc \
    && chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zshrc

# git@github.com: remotes go to the git relay, which checks them against the
# policy and authenticates with its own key (see egress/git-relay/).
# https://github.com/ remotes go through the egress proxy, fetch-only.
COPY egress/git-relay/client_ssh_config /etc/ssh/ssh_config.d/git-relay.conf
RUN git config --system url."git-relay:".insteadOf "git@github.com:" \
    && git config --system --add url."git-relay:".insteadOf "ssh://git@github.com/"

# claude
COPY claude/managed-settings.json /etc/claude-code/managed-settings.json

COPY dotfiles/vimrc /home/${USERNAME}/.vimrc
RUN chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.vimrc
ENV EDITOR=vim

# Python virtualenv owned by the dev user
RUN python -m venv /opt/venv && chown -R ${USERNAME}:${USERNAME} /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# cowsay and fortunes
ENV PATH="${PATH}:/usr/games"

# Pre-create volume targets so they're owned by the dev user, not root
RUN mkdir -p /home/${USERNAME}/.local/share/Odoo /home/${USERNAME}/.claude /odoo \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /odoo

# Sets up /odoo/<repo> from the host's repos (postCreateCommand)
COPY odoo/seed-repos.sh /usr/local/bin/seed-repos

# Odoo config (copied into the image, not mounted). ODOO_RC makes odoo-bin pick it up.
COPY odoo/odoo.conf /etc/odoo/odoo.conf
ENV ODOO_RC=/etc/odoo/odoo.conf
