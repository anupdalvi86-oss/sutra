FROM nousresearch/hermes-agent:latest

# Preserve Hermes' official entrypoint/s6 supervision and isolate its secrets
# from the separate Sutra API container.
USER root
COPY hermes/SOUL.md /opt/sutra/SOUL.md
COPY hermes/seed-soul.sh /etc/cont-init.d/30-sutra-seed-soul
RUN chmod 0755 /etc/cont-init.d/30-sutra-seed-soul
USER hermes

ENV HERMES_HOME=/opt/data \
    API_SERVER_ENABLED=true \
    API_SERVER_HOST=127.0.0.1 \
    API_SERVER_PORT=8642

CMD ["gateway", "run"]
