FROM timescale/timescaledb:2.17.2-pg17

LABEL org.opencontainers.image.title="SmartPot DB (PostgreSQL + TimescaleDB)" \
      org.opencontainers.image.description="PostgreSQL con TimescaleDB para SmartPot: esquema relacional, hipertabla de telemetría y datos demo opcionales" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-DB-Postgre" \
      org.opencontainers.image.licenses="MIT"

ENV POSTGRES_DB=smartpot \
    SMARTPOT_DB_USERNAME=smartpot \
    SMARTPOT_SEED_DEMO=false

# El esquema y el seed los comparten el inicio de una base nueva y la migración de una existente.
COPY schema/schema.sql schema/demo.sql /opt/smartpot/
COPY scripts/migrate.sh /opt/smartpot/migrate.sh
COPY init/01_init.sh /docker-entrypoint-initdb.d/01_init.sh
RUN chmod 0755 /opt/smartpot/migrate.sh /docker-entrypoint-initdb.d/01_init.sh

EXPOSE 5432

HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-smartpot}" || exit 1
