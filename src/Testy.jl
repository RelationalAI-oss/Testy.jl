module Testy

using Base.PCRE
using Distributed
using Suppressor
using Test

include("pmatch.jl")

eat(args...) = nothing

const trace_enabled = false
if trace_enabled
    trace = print
    traceln = println
else
    trace = eat
    traceln = eat
end

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
mutable struct ParallelState
    # Channel for retrieving @testset indices to process
    jobs::AbstractChannel{Int}

    # Channel for sending results
    results::AbstractChannel{Any}

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

TestState(s::TestState) = TestState(copy(s.stack), s.include, s.exclude,
    copy(s.seen), s.dryrun, s.ts_depth, s.ts_count, s.parallel_state)

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
    traceln("Closing $(rs.stack)")
    pop!(rs.stack)
    if !testsuite
        rs.ts_depth -= 1
    end

    if shouldrun && !testsuite && rs.parallel_state != nothing && rs.ts_depth == 0
        # Fetch next job
        rs.parallel_state.ts_next = take!(rs.parallel_state.jobs)
        traceln("Got job $(rs.parallel_state.ts_next)")
    else
        traceln("Not fetching next job ($shouldrun, $(rs.ts_depth))")
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

function tally(state::TestState, set::Test.AbstractTestSet)
    if state.parallel_state != nothing
        traceln("Putting result...")
        put!(state.parallel_state.results, set)
        traceln("Done.")
    end
end

function tally(state::TestState, err::Exception)
    if state.parallel_state != nothing
        traceln("Putting exception...")
        put!(state.parallel_state.results, err)
        traceln("Done.")
    end
end

function tally(state::TestState, sets::AbstractVector)
    for set in sets
        tally(state, set)
    end
end

function tally(state::TestState, any)
    printstyled("tally\n"; color=:light_red)
    for fr in stacktrace()
        printstyled(" $fr\n", color=:light_red)
    end
    error(stacktrace())
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
            trace("  "^length(rs.stack))
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
                tally(rs, ts)   # @testset ... begin ... end
            catch err
                err isa InterruptException && rethrow()
                tally(rs, err)
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

    if num_workers == 1 || dryrun
        runtests_serial(filename, state)
    else
        runtests_parallel(filename, state, num_workers)
    end

    state
end

function runtests_serial(filename::String, state::TestState)
    task_local_storage(:__TESTY_STATE__, state) do
        if state.dryrun
            @suppress include(filename)
        else
            include(filename)
        end
    end
end

function runtests_worker(path::String, filename::String, state::TestState,
    jobs::AbstractChannel, results::AbstractChannel, job::Int)
    # try
        traceln("path=$path, filename=$filename, job=$job")

        state.parallel_state = ParallelState(jobs, results, job)
        task_local_storage(:__TESTY_STATE__, state) do
            task_local_storage(:SOURCE_PATH, path) do
                @suppress include(filename)
            end
        end

        traceln("Putting done...")
        # dump(results)
        put!(results, state)
        traceln("Done.")
    # catch err
    #     printstyled("EGADS!!!\n"; color=:green)
    #     println(err)
    #     printstyled("printing backtrace\n"; color=:green)
    #     show(stacktrace(catch_backtrace()))
    #     println()
    #     printstyled("EGADS!!! (end)\n"; color=:green)
    #     # rethrow(err)
    # end
end

function ntests(filename::String, state::TestState)
    state2 = TestState(state.include, state.exclude, true)
    runtests_serial(filename, state2)
    state2.ts_count
end

function runtests_parallel(filename::String, state::TestState, num_workers::Int)
    num_jobs = ntests(filename, state)
    num_workers = max(min(num_workers, num_jobs), 1)

    # if num_workers == 1
    #     msg = num_jobs == 0 ? "no top-level test sets were" : "only one top-level test set was"
    #     @warn "Running tests in serial as $msg found"
    #     return runtests_serial(filename, state)
    # end
    num_workers = 2

    printstyled("Running tests in parallel with $num_workers workers\n",
        color=:cyan)

    result_vector = Vector{Any}()

    try
        jobs = #RemoteChannel() do
            Channel(ctype=Int, csize=0) do jobs
                for i in num_workers+1:num_jobs
                    traceln("Putting job $i")
                    put!(jobs, i)
                end
                for i in 1:num_workers
                    put!(jobs, 0)
                end
            end
        #end

        taskref = Ref{Task}()
        results = #RemoteChannel() do
            Channel(ctype=Any, csize=0, taskref=taskref) do results
                completed = 0
                while completed < num_workers
                    result = take!(results)
                    traceln("Got result: $(typeof(result))")
                    push!(result_vector, result)
                    if result isa TestState
                        completed += 1
                    # elseif result isa Exception
                    #     throw(result)
                    end
                end
                traceln("Done collecting results")
            end
        #end

        path = task_local_storage(:SOURCE_PATH)

        pids = workers()
        for i in 1:num_workers
            @async(runtests_worker(path, filename, TestState(state),
                jobs, results, i))
        end

        wait(taskref[])

        collate_results!(state, result_vector)

        printstyled("Results:\n"; color=:light_yellow)
        for r in result_vector
            printstyled(r; color=:light_yellow)
            println()
        end

    catch err
        sleep(20)
        rethrow(err)
    end
end

function collate_results!(state::TestState, results::Vector{Any})
    for result in results
        if result isa TestState
            traceln("collate_results: appending ", result.seen)
            append!(state.seen, result.seen)
        end
    end
    state.seen = unique(state.seen) # KLUDGE, FIXME
    traceln("collage_results: => ", state.seen)
    state
end

# function runtests_distributed(filename::String, state::TestState, num_workers::Int)
#     num_jobs = ntests(filename, state)
#     num_workers = max(min(num_workers, num_jobs), 1)
#
#     if num_workers == 1
#         msg = num_jobs == 0 ? "no top-level test sets were" : "only one top-level test set was"
#         @warn "Running tests in serial as $msg found"
#         return runtests_serial(filename, state)
#     end
#
#     addprocs(max(0, num_workers-nworkers()))
#
#     printstyled("Running tests in parallel with $num_workers workers\n",
#         color=:cyan)
#
#     @everywhere @eval(Main, using Testy)
#
#     result_vector = Vector{Any}()
#
#     try
#         @sync begin
#             jobs = RemoteChannel(()->Channel{Int}(0)) do
#                 for i in num_workers:num_jobs
#                     println("Putting job $i")
#                     put!(jobs, i)
#                 end
#             end
#
#             path = task_local_storage(:SOURCE_PATH)
#
#             pids = workers()
#             for i in 1:num_workers
#                 @spawnat(pids[i], runtests_worker(path, filename, state,
#                     jobs, results, i))
#             end
#
#             results = RemoteChannel(()->Channel{Any}(0))
#
#             @async begin
#                 completed = 0
#                 while completed < num_workers
#                     result = take!(results)
#                     push!(result, result_vector)
#
#                     println("Got result: $(typeof(result))")
#                     if result isa TestState
#                         completed += 1
#                     end
#                 end
#                 println("Done collecting results")
#             end
#         end
#     catch err
#         if err isa CompositeException
#             @info :distributed_run_catch err    # TODO
#             push!(err, result_vector)
#         else
#             @info :distributed_run_catch err
#             push!(err, result_vector)
#         end
#     end
#
#     collate_results!(state, result_vector)
# end

"""
List test suites and top-level test sets.
"""
function showtests(filename="test/runtests.jl")
    state = runtests(; filename=filename, dryrun=true)
    map(kv -> kv[1], state.seen)
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
