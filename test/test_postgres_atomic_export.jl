using Test
using DataFrames
using QuansiftMarketData

@testset "single-table PostgreSQL export preflights before staging" begin
    postgres_module = QuansiftMarketData.DB.Postgres
    events = Any[]
    plan = postgres_module.prepare_single_postgres_export(
        :pg,
        "prices";
        require_idle=(conn, operation) -> push!(events, (:idle, conn, operation)),
    )
    @test plan.target == "prices"
    @test events == [(:idle, :pg, "single-table PostgreSQL export")]

    empty!(events)
    idle_error = ErrorException("caller-owned transaction is active")
    require_idle = function (_, _)
        push!(events, :idle)
        throw(idle_error)
    end

    caught = try
        postgres_module.prepare_single_postgres_export(
            :pg,
            "prices";
            require_idle,
        )
        nothing
    catch error
        error
    end

    @test caught === idle_error
    @test events == [:idle]
end

@testset "deprecated PostgreSQL export plans are unique and validated" begin
    postgres_module = QuansiftMarketData.DB.Postgres

    @test_throws ArgumentError postgres_module.build_postgres_export_plans(String[])
    @test_throws ArgumentError postgres_module.build_postgres_export_plans([""])
    @test_throws ArgumentError postgres_module.build_postgres_export_plans(["prices", "PRICES"])

    first_plans = postgres_module.build_postgres_export_plans(["prices", "metrics"])
    second_plans = postgres_module.build_postgres_export_plans(["prices", "metrics"])

    @test getproperty.(first_plans, :target) == ["prices", "metrics"]
    @test all(plan -> length(plan.staging) <= 63, first_plans)
    @test all(plan -> occursin(r"^_tiingo_stage_[0-9a-f]+$", plan.staging), first_plans)
    @test length(unique(getproperty.(first_plans, :staging))) == 2
    @test isempty(
        intersect(
            Set(getproperty.(first_plans, :staging)),
            Set(getproperty.(second_plans, :staging)),
        ),
    )
end

@testset "unique staging tables retain the target key schema" begin
    postgres_module = QuansiftMarketData.DB.Postgres
    schema_module = QuansiftMarketData.DB.Schema
    staging = only(
        postgres_module.build_postgres_export_plans(["historical_data"]),
    ).staging
    schema = DataFrame(
        column_name = ["ticker", "date", "close"],
        column_type = ["VARCHAR", "DATE", "DOUBLE"],
    )

    query = schema_module.generate_create_table_query(
        staging,
        schema;
        base_table_name="historical_data",
    )
    @test occursin("PRIMARY KEY (\"ticker\", \"date\")", query)
end

@testset "deprecated PostgreSQL batch publication owns one transaction" begin
    postgres_module = QuansiftMarketData.DB.Postgres
    plans = [
        (target = "prices", staging = "_tiingo_stage_1"),
        (target = "metrics", staging = "_tiingo_stage_2"),
    ]
    events = Any[]
    require_idle = (conn, operation) -> push!(events, (:idle, conn, operation))
    execute = (conn, sql) -> push!(events, (:sql, conn, sql))
    publish = (conn, target, staging) ->
        push!(events, (:publish, conn, target, staging))

    @test isnothing(postgres_module.publish_postgres_tables!(
        :pg,
        plans;
        require_idle,
        execute,
        publish,
    ))
    @test events == [
        (:idle, :pg, "PostgreSQL batch table replacement"),
        (:sql, :pg, "BEGIN"),
        (:publish, :pg, "prices", "_tiingo_stage_1"),
        (:publish, :pg, "metrics", "_tiingo_stage_2"),
        (:sql, :pg, "COMMIT"),
    ]

    empty!(events)
    publish_error = ErrorException("simulated second-table publish failure")
    failing_publish = function (conn, target, staging)
        push!(events, (:publish, conn, target, staging))
        target == "metrics" && throw(publish_error)
        return nothing
    end
    caught = try
        postgres_module.publish_postgres_tables!(
            :pg,
            plans;
            require_idle,
            execute,
            publish=failing_publish,
        )
        nothing
    catch error
        error
    end
    @test caught === publish_error
    @test events == [
        (:idle, :pg, "PostgreSQL batch table replacement"),
        (:sql, :pg, "BEGIN"),
        (:publish, :pg, "prices", "_tiingo_stage_1"),
        (:publish, :pg, "metrics", "_tiingo_stage_2"),
        (:sql, :pg, "ROLLBACK"),
    ]
end

@testset "deprecated PostgreSQL export orchestration always cleans owned stages" begin
    postgres_module = QuansiftMarketData.DB.Postgres
    plans = [
        (target = "prices", staging = "_tiingo_stage_1"),
        (target = "metrics", staging = "_tiingo_stage_2"),
    ]
    all_stages = getproperty.(plans, :staging)

    events = Any[]
    stage = (_, _, plan) -> push!(events, (:stage, plan.target))
    publish = (_, received) -> push!(events, (:publish, getproperty.(received, :target)))
    cleanup = (_, stages) -> push!(events, (:cleanup, copy(stages)))
    @test isnothing(postgres_module.execute_postgres_export_plans!(
        :duck,
        :pg,
        plans;
        max_retries=1,
        retry_delay=0,
        stage,
        publish,
        cleanup,
    ))
    @test (:publish, ["prices", "metrics"]) in events
    @test last(events) == (:cleanup, all_stages)

    empty!(events)
    load_error = ErrorException("simulated load failure")
    failing_stage = function (_, _, plan)
        push!(events, (:stage, plan.target))
        plan.target == "metrics" && throw(load_error)
        return nothing
    end
    caught = try
        postgres_module.execute_postgres_export_plans!(
            :duck,
            :pg,
            plans;
            max_retries=1,
            retry_delay=0,
            stage=failing_stage,
            publish,
            cleanup,
        )
        nothing
    catch error
        error
    end
    @test caught === load_error
    @test !any(event -> first(event) == :publish, events)
    @test last(events) == (:cleanup, all_stages)

    empty!(events)
    publish_error = ErrorException("simulated publish failure")
    failing_batch_publish = function (_, received)
        push!(events, (:publish, getproperty.(received, :target)))
        throw(publish_error)
    end
    caught = try
        postgres_module.execute_postgres_export_plans!(
            :duck,
            :pg,
            plans;
            max_retries=1,
            retry_delay=0,
            stage,
            publish=failing_batch_publish,
            cleanup,
        )
        nothing
    catch error
        error
    end
    @test caught === publish_error
    @test last(events) == (:cleanup, all_stages)

    empty!(events)
    publish_attempts = Ref(0)
    retrying_publish = function (_, received)
        publish_attempts[] += 1
        push!(events, (:publish, getproperty.(received, :target)))
        publish_attempts[] == 1 && error("transient publish failure")
        return nothing
    end
    @test isnothing(postgres_module.execute_postgres_export_plans!(
        :duck,
        :pg,
        plans;
        max_retries=2,
        retry_delay=0,
        stage,
        publish=retrying_publish,
        cleanup,
    ))
    @test count(event -> first(event) == :stage, events) == 2
    @test count(event -> first(event) == :publish, events) == 2
    @test last(events) == (:cleanup, all_stages)
end
