module Testy

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
State maintained during a test run.
"""
mutable struct TestyState
    stack::Vector{String}
    include::Regex
    exclude::Regex
    seen::Dict{String,Bool}
    dryrun::Bool
    underset::Bool
end

function open_testset(rs::TestyState, name::String)
    push!(rs.stack, name)
    join(rs.stack, "/")
end

function close_testset(rs::TestyState)
    pop!(rs.stack)
end

const ⊤ = r""       # matches any string
const ⊥ = r"(?!)"   # matches no string

TestyState() = TestyState([], ⊤, ⊥, Dict{String,Bool}(), false, false)

TestyState(include::Regex, exclude::Regex, dryrun::Bool) =
   TestyState([], include, exclude, Dict{String,Bool}(), dryrun, false)

function checked_ts_expr(name::Expr, ts_expr::Expr, testsuite::Bool)
    quote
        tls = task_local_storage()
        rs = haskey(tls, :__TESTY_STATE__) ? tls[:__TESTY_STATE__] : TestyState()

        # Guard against nesting of @testsuite under @testset
        if $(testsuite) && rs.underset
            error("Nested @testsuite under @testset is disallowed")
        elseif !$testsuite
            rs.underset = true
        end

        path = open_testset(rs, $name)
        shouldrun = !(rs.dryrun && !$testsuite) &&
                pmatch(rs.include, path) != nothing && pmatch(rs.exclude, path) == nothing
        rs.seen[path] = shouldrun

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
            $ts_expr
        end

        close_testset(rs)
    end
end

"""
Wrapped version of `Base.Test.@testset`.  In Testy, test sets are also the
smallest unit of parallelism.
"""
macro testset(args...)
    ts_expr = esc(:($Test.@testset($(args...))))
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr, false)
end

"""
Like `Base.Test.@testset`, but used at a higher level to encapsulate a
collection of test sets (possibly further nested within suites) that can be run
in parallel.
"""
macro testsuite(args...)
    ts_expr = esc(:($Test.@testset($(args...))))
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr, true)
end

function runtests(fun::Function, dryrun::Bool, args...)
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
    state = TestyState(include, exclude, dryrun)
    task_local_storage(:__TESTY_STATE__, state) do
        fun()
    end
    state
end

function include_runtests()
    testfile = pwd() * "/test/runtests.jl"
    if !isfile(testfile)
        @error("Could not find test/runtests.jl")
        return
    end
    include(testfile)
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
runtests(args...) = runtests(include_runtests, false, args...)

"""
List test suites and top-level test sets.
"""
function showtests(fun::Function=include_runtests)
    state = runtests(fun, true)
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
