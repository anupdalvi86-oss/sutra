FROM nousresearch/hermes-agent:latest@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db

# Preserve Hermes' official entrypoint/s6 supervision and isolate its secrets
# from the separate Sutra API container.
USER root
COPY hermes/SOUL.md /opt/sutra/SOUL.md
COPY hermes/seed-soul.sh /etc/cont-init.d/30-sutra-seed-soul
RUN chmod 0755 /etc/cont-init.d/30-sutra-seed-soul

ENV HERMES_HOME=/opt/data
ENV API_SERVER_ENABLED=false
ENV API_SERVER_HOST=0.0.0.0
ENV API_SERVER_PORT=8642

CMD ["gateway", "run"]
