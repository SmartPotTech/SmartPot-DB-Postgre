# Etapa de preparación: se parte de la imagen oficial de TimescaleDB y se ajusta su sistema de archivos.
FROM timescale/timescaledb:2.17.2-pg17 AS base

# La imagen de TimescaleDB 2.17.2 es de enero de 2025: se actualizan los paquetes de Alpine. Sus binarios en Go
# arrastran una librería estándar vieja: timescaledb-tune y timescaledb-parallel-copy no se usan (01_init.sh fija la
# configuración con ALTER SYSTEM) y gosu se reemplaza por su-exec (C, misma sintaxis) para que el entrypoint siga
# preparando el directorio de datos como root y luego baje a postgres.
RUN apk upgrade --no-cache \
    && apk add --no-cache su-exec \
    && rm -f /usr/local/bin/timescaledb-tune /usr/local/bin/timescaledb-parallel-copy \
             /docker-entrypoint-initdb.d/001_timescaledb_tune.sh \
    && install -m 0755 /sbin/su-exec /usr/local/bin/gosu

# El esquema y el seed los comparten el inicio de una base nueva y la migración de una existente.
COPY schema/schema.sql schema/demo.sql /opt/smartpot/
COPY scripts/migrate.sh /opt/smartpot/migrate.sh
COPY init/01_init.sh /docker-entrypoint-initdb.d/01_init.sh
RUN chmod 0755 /opt/smartpot/migrate.sh /docker-entrypoint-initdb.d/01_init.sh

# Etapa final: el sistema de archivos ya ajustado en una sola capa. Reemplazar o borrar un archivo en una capa nueva
# solo lo oculta: el gosu original (Go con stdlib 1.18.2, cuatro CVE críticas) seguiría dentro de la capa base y
# viajaría con la imagen. Al copiar el resultado sobre scratch, ese binario y los paquetes viejos de Alpine ya no se
# distribuyen.
FROM scratch

COPY --from=base / /

LABEL org.opencontainers.image.title="SmartPot DB (PostgreSQL + TimescaleDB)" \
      org.opencontainers.image.description="PostgreSQL con TimescaleDB para SmartPot: esquema relacional, hipertabla de telemetría y datos demo opcionales" \
      org.opencontainers.image.source="https://github.com/SmartPotTech/SmartPot-DB-Postgre" \
      org.opencontainers.image.licenses="MIT"

# Configuración heredada de timescale/timescaledb:2.17.2-pg17 (scratch no la trae) más la propia de SmartPot.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.utf8 \
    PG_MAJOR=17 \
    PG_VERSION=17.2 \
    PGDATA=/var/lib/postgresql/data \
    POSTGRES_DB=smartpot \
    SMARTPOT_DB_USERNAME=smartpot \
    SMARTPOT_SEED_DEMO=false

VOLUME /var/lib/postgresql/data
STOPSIGNAL SIGINT
EXPOSE 5432

HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-smartpot}" || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
