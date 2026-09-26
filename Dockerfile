FROM nousresearch/hermes-agent:latest

USER root
COPY hermes/SOUL.md /opt/sutra/SOUL.md
COPY hermes/entrypoint.sh /opt/sutra/entrypoint.sh
RUN chmod +x /opt/sutra/entrypoint.sh

ENTRYPOINT ["/opt/sutra/entrypoint.sh"]
