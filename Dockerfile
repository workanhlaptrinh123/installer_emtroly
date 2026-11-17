FROM vps-user-env:latest
RUN apt-get update \
 && apt-get install -y --no-install-recommends antiword catdoc librsvg2-bin imagemagick tesseract-ocr tesseract-ocr-eng tesseract-ocr-vie \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g openclaw@2026.11.4 --no-audit --no-fund
RUN node "$(npm root -g)/openclaw/scripts/postinstall-bundled-plugins.mjs"
COPY modules /opt/member-vps/modules
COPY profiles /opt/member-vps/profiles
COPY native/skills /opt/member-vps/skills
COPY native/module-skills.json /opt/member-vps/module-skills.json
COPY docker/install-modules.sh /usr/local/sbin/member-install-modules
COPY docker/module-manager.py /usr/local/sbin/member-module
COPY entrypoint.sh /golden-entrypoint.sh
RUN chmod 755 /golden-entrypoint.sh /usr/local/sbin/member-install-modules /usr/local/sbin/member-module
ENTRYPOINT ["/golden-entrypoint.sh"]
