module Testy

using Distributed
using Test

include("pmatch.jl")

# struct TestySet <: Test.AbstractTestSet
#     parent::Test.DefaultTestSet
#
#     function TestySet(description::String)
#         new(Test.DefaultTestSet(description))
#     end
# end
#
# function Test.record(ts::TestySet, res::Test.Result)
#     # println("Recording $res for $(Test.get_test_set()) at depth $(Test.get_testset_depth())")
#     Test.record(ts.parent, res)
# end
#
# function Test.finish(ts::TestySet)
#     # println("Finishing")
#     Test.finish(ts.parent)
# end

"""
State for parallel test workers.
"""
struct ParallelState
    # Channel for retrieving @testset indices to process
    jobs::RemoteChannel{Channel{Int}}

    # Channel for sending results
    results::RemoteChannel{Channel{Any}}

    # Index of the next top-level @testset this worker should run
    ts_next::Int
end

"""
State maintained during a test run.
"""
mutable struct TestState
    stack::Vector{String}
    include::Regex
    exclude::Regex

    # test sets/suites encountered
    seen::Vector{Tuple{String,Bool}}
    dryrun::Bool

    # depth of current @testset nesting
    ts_depth::Int

    # Count of top-level @testsets encountered so far by this worker
    ts_count::Int

    # state for parallel workers
    parallel_state::Union{ParallelState, Nothing}
end

const ⊤ = r""       # matches any string
const ⊥ = r"(?!)"   # matches no string

TestState() = TestState([], ⊤, ⊥, [], false, 0, 0, nothing)

TestState(include::Regex, exclude::Regex, dryrun::Bool) =
   TestState([], include, exclude, [], dryrun, 0, 0, nothing)

function open_testset(rs::TestState, name::String, testsuite::Bool)
    # Guard against nesting of @testsuite under @testset
    if testsuite && rs.ts_depth > 0
        error("Nested @testsuite under @testset is disallowed")
    elseif !testsuite
        if rs.ts_depth == 0
            rs.ts_count += 1
        end
        rs.ts_depth += 1
    end

    push!(rs.stack, name)
    join(rs.stack, "/")
end

function close_testset(rs::TestState, testsuite::Bool, shouldrun::Bool)
    pop!(rs.stack)
    if !testsuite
        rs.ts_depth -= 1
    end

    if shouldrun && rs.parallel_state != nothing && rs.ts_depth == 0
        # Fetch next job
        rs.parallel_state.ts_next = take!(rs.parallel_state.jobs)
    end
end

function ts_should_run(rs::TestState, path::String, testsuite::Bool)
    if !(rs.dryrun && !testsuite) &&
        pmatch(rs.include, path) != nothing &&
        pmatch(rs.exclude, path) == nothing

        if testsuite || rs.parallel_state == nothing
            return true
        elseif rs.parallel_state != nothing &&
            rs.ts_count == rs.parallel_state.ts_next
            return true
        end

    end
    return false
end

function Test.record(state::TestState, set::Test.AbstractTestSet)
    if state.parallel_state != nothing
        put!(state.parallel_state.results, set)
    end
end

function Test.record(state::TestState, err::TestSetException)
    if state.parallel_state != nothing
        put!(state.parallel_state.results, err)
    end
end

function checked_ts_expr(name::Expr, ts_expr::Expr, testsuite::Bool, source)
    quote
        tls = task_local_storage()
        rs = haskey(tls, :__TESTY_STATE__) ? tls[:__TESTY_STATE__] : TestState()

        path = open_testset(rs, $name, $testsuite)
        shouldrun = ts_should_run(rs, path, $testsuite)
        push!(rs.seen, (path, shouldrun))

        # Suppress status output during dry runs
        if !rs.dryrun
            print("  "^length(rs.stack))
            label = $testsuite ? "test suite" : "test set"
            if shouldrun
                print("Running ")
                printstyled(path; bold=true)
                println(" $label...")
            else
                printstyled("Skipping $path $label...\n"; color=:light_black)
            end
        end

        if shouldrun
            try
                ts = $ts_expr
                record(rs, ts)
            catch err
                err isa InterruptException && rethrow()
                record(rs, err)
            end
        end

        close_testset(rs, $testsuite, shouldrun)
    end
end

"""
Wrapped version of `Base.Test.@testset`.  In Testy, test sets are also the
smallest unit of parallelism.
"""
macro testset(args...)
    ts_expr = esc(:($Test.@testset($(args...))))
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr, false, __source__)
end

"""
Like `Base.Test.@testset`, but used at a higher level to encapsulate a
collection of test sets (possibly further nested within suites) that can be run
in parallel.
"""
macro testsuite(args...)
    ts_expr = esc(:($Test.@testset($(args...))))
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr, true, __source__)
end

function get_num_workers()
    str = get(ENV, "TESTY_WORKERS", "")
    if str == ""
        return 1
    else
        try
            num_workers = parse(Int, str)
            if num_workers > 0
                return num_workers
            end
        catch
        end

        warn("Invalid number of workers in TESTY_WORKERS: $str")
        return 1
    end
end

"""
Include file `test/runtests.jl` and execute test sets, optionally restricting
them to those matching the regular expressions in `args`.  (A leading '!'
indicates that tests matching the expression should be excluded.)

 # Examples
 ```jldoctest
julia> runtests("t/a/.*")           # Run all tests under `t/a`

julia> runtests("t/.*", "!t/b/2")   # Run all tests under `t` except `t/b/2`
 ```
"""
function runtests(args...; filename::String="test/runtests.jl", dryrun::Bool=false)
    # if !isfile(filename)
    #     error("Cannot find test file $filename")
    # end

    includes = []
    excludes = ["(?!)"]     # seed with an unsatisfiable regex
    for arg in args
        if startswith(arg, "!")
            push!(excludes, arg[nextind(arg,1):end])
        else
            push!(includes, arg)
        end
    end
    include = partial(join(includes, "|"))
    exclude = exact(join(excludes, "|"))
    state = TestState(include, exclude, dryrun)

    num_workers = get_num_workers()

    if num_workers == 1
        runtests_serial(filename, state)
    else
        runtests_parallel(filename, state, num_workers)
    end

    state
end

function runtests_serial(filename::String, state::TestState)
    task_local_storage(:__TESTY_STATE__, state) do
        include(filename)
    end
end

function runtests_worker(filename::String, state::TestState,
    jobs::RemoteChannel, results::RemoteChannel, job::Int)

    state.parallel_state = ParallelState(jobs, results, 0, job)
    task_local_storage(:__TESTY_STATE__, state) do
        include(filename)
    end

    put!(results, :worker_done)
end

function ntests(filename::String, state::TestState)
    (dryrun, state.dryrun) = (state.dryrun, true)
    runtests_serial(filename, state)
    state.dryrun = dryrun
end

function runtests_parallel(filename::String, state::TestState, num_workers::Int)
    num_jobs = ntests(filename, state)
    num_workers = max(min(num_workers, num_jobs), 1)

    addprocs(max(0, num_workers-nworkers()))

    printstyled("Running tests in parallel with $(nworkers()) workers\n",
        color=:cyan)

    @everywhere @eval(Main, using Testy)

    jobs = RemoteChannel(()->Channel{Int}(num_jobs))
    results = RemoteChannel(()->Channel{Any}(0))

    result_vector = Vector{Any}()

    try
        @sync begin
            for (i,pid) in enumerate(workers())
                @spawnat(pid, runtests_worker(filename, state, jobs, results, i))
            end

            for i in num_workers:num_jobs
                put!(jobs, i)
            end

            @async begin
                completed = 0
                while completed < num_workers
                    result = take!(results)
                    if result == :worker_done
                        completed += 1
                    else
                        push!(result, results)
                    end
                end
            end
        end
    catch err
        if err isa CompositeException
            @info :distributed_run_catch err    # TODO
        else
            @info :distributed_run_catch err
        end
    end

    result_vector
end

"""
List test suites and top-level test sets.
"""
function showtests(filename="test/runtests.jl")
    state = runtests(filename, true)
    collect(keys(state.seen))
end

export @testset, @testsuite, @test_broken
export runtests, showtests

#
# Purely delegated macros and functions
#
using Test: @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated
using Test: @inferred
using Test: detect_ambiguities, detect_unbound_args
using Test: GenericString, GenericSet, GenericDict, GenericArray
using Test: TestSetException
using Test: get_testset, get_testset_depth
using Test: AbstractTestSet, DefaultTestSet, record, finish

export @test, @test_throws, @test_broken, @test_skip,
    @test_warn, @test_nowarn, @test_logs, @test_deprecated
export @inferred
export detect_ambiguities, detect_unbound_args
export GenericString, GenericSet, GenericDict, GenericArray
export TestSetException
export get_testset, get_testset_depth
export AbstractTestSet, DefaultTestSet, record, finish

end
