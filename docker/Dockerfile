FROM julia:1.12.1-bookworm

ENV JULIA_PROJECT=/app \
    JULIA_DEPOT_PATH=/usr/local/julia-depot: \
    TIINGO_LOGGER=console

WORKDIR /app

COPY Project.toml ./
RUN julia -e 'using Pkg; Pkg.instantiate()'

COPY src ./src
COPY scripts ./scripts
COPY README.md LICENSE config.toml config.example.toml .env.example ./

RUN julia -e 'using Pkg; Pkg.precompile(); using TiingoJulia'

RUN useradd --create-home --shell /bin/bash appuser && \
    chown -R appuser:appuser /app /usr/local/julia-depot

USER appuser

ENTRYPOINT ["julia", "--project=/app"]
CMD ["-e", "using TiingoJulia; println(\"TiingoJulia image ready\")"]
