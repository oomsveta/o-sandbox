# The dev container. Odoo 17 to 19 run on Python 3.10 to 3.12; for Odoo 16 or
# older, use 3.10.
ARG PYTHON_VERSION=3.12
FROM node:26-trixie AS node
FROM python:${PYTHON_VERSION}-trixie

ARG TARGETARCH
RUN curl -fsSLo /tmp/wkhtmltox.deb https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_${TARGETARCH}.deb \
    && apt-get update && apt-get install -y --no-install-recommends \
        # To build Python packages with C extensions: a compiler, and headers
        # for psycopg2, python-ldap, lxml, Pillow and cffi
        build-essential libpq-dev libldap2-dev libsasl2-dev libxml2-dev \
        libxslt1-dev libjpeg-dev zlib1g-dev libffi-dev \
        # PDF reports
        /tmp/wkhtmltox.deb \
        # Headless browser for tour/HttpCase tests, and fonts for it and PDFs
        chromium fonts-liberation \
        postgresql-client sudo zsh vim \
        cowsay fortune-mod fortunes fortunes-debian-hints \
    && rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && npm install -g rtlcss

# The user VS Code runs as (remoteUser), with passwordless sudo. Its name and
# uid are also in docker-compose.yml, odoo/odoo.conf and egress/git-relay/start.sh.
RUN useradd --uid 1000 --user-group --create-home --shell /bin/zsh dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# A virtualenv the dev user can pip install into.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir phonenumbers \
    && chown -R dev:dev /opt/venv

# /usr/games: cowsay and fortune
ENV PATH="/opt/venv/bin:${PATH}:/usr/games" \
    EDITOR=vim \
    ODOO_RC=/etc/odoo/odoo.conf

# Volume mount points (see docker-compose.yml), created here so that the
# volumes belong to the dev user, not root.
RUN mkdir -p /odoo /home/dev/.claude /home/dev/.local/share/Odoo \
    && chown -R dev:dev /odoo /home/dev

# git@github.com: remotes go to the git relay (see egress/git-relay/).
COPY egress/git-relay/client_ssh_config /etc/ssh/ssh_config.d/git-relay.conf
RUN git config --system url."git-relay:".insteadOf "git@github.com:" \
    && git config --system --add url."git-relay:".insteadOf "ssh://git@github.com/"

COPY claude/managed-settings.json /etc/claude-code/managed-settings.json
COPY claude/link-skills.sh /usr/local/bin/link-skills
COPY odoo/odoo.conf /etc/odoo/odoo.conf
COPY odoo/seed-repos.sh /usr/local/bin/seed-repos
COPY dotfiles/check-ssh-agent.sh /usr/local/bin/check-ssh-agent
COPY --chown=dev:dev dotfiles/zshrc /home/dev/.zshrc
COPY --chown=dev:dev dotfiles/gitconfig /home/dev/.gitconfig
