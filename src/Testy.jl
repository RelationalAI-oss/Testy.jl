module Testy

using Test

# TODO refactor into patch to bring these into Base
function pexec(re,subject,offset,options,match_data)
    rc = ccall((:pcre2_match_8, Base.PCRE.PCRE_LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Csize_t, Cuint, Ptr{Cvoid}, Ptr{Cvoid}),
               re, subject, sizeof(subject), offset, options, match_data, Base.PCRE.MATCH_CONTEXT[])
    # rc == -1 means no match, -2 means partial match.
    rc < -2 && error("PCRE.exec error: $(err_message(rc))")
    rc
end

function pmatch(re::Regex, str::Union{SubString{String}, String}, idx::Integer, add_opts::UInt32=UInt32(0))
    Base.compile(re)
    opts = re.match_options | add_opts
    # rc == -1 means no match, -2 means partial match.
    rc = pexec(re.regex, str, idx-1, opts, re.match_data)
    if rc == -1 || (rc == -2 && (re.match_options & Base.PCRE.PARTIAL_HARD) == 0)
        return nothing
    end
    ovec = re.ovec
    n = div(length(ovec),2) - 1
    mat = SubString(str, ovec[1]+1, prevind(str, ovec[2]+1))
    cap = Union{Nothing,SubString{String}}[ovec[2i+1] == PCRE.UNSET ? nothing :
                                        SubString(str, ovec[2i+1]+1,
                                                  prevind(str, ovec[2i+2]+1)) for i=1:n]
    off = Int[ ovec[2i+1]+1 for i=1:n ]
    RegexMatch(mat, cap, ovec[1]+1, off, re)
end

pmatch(r::Regex, s::AbstractString) = pmatch(r, s, firstindex(s))
pmatch(r::Regex, s::AbstractString, i::Integer) = throw(ArgumentError(
    "regex matching is only available for the String type; use String(s) to convert"
))

struct TestySet <: Test.AbstractTestSet
    parent::Test.DefaultTestSet

    function TestySet(description::String)
        new(Test.DefaultTestSet(description))
    end
end

function Test.record(ts::TestySet, res::Test.Result)
    # println("Recording $res for $(Test.get_test_set()) at depth $(Test.get_testset_depth())")
    Test.record(ts.parent, res)
end

function Test.finish(ts::TestySet)
    # println("Finishing")
    Test.finish(ts.parent)
end

struct TestyState
    stack::Vector{String}
    include::Regex
    exclude::Regex
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

function checked_ts_expr(name::Expr, ts_expr::Expr)
    quote
        rs = get(task_local_storage(), :__TESTY_STATE__, TestyState([], ⊤, ⊥))
        path = open_testset(rs, $name)
        if pmatch(rs.include, path) != nothing && pmatch(rs.exclude, path) == nothing
            $ts_expr
        end
        close_testset(rs)
    end
end

macro testset(args...)
    ts_expr = esc(:($Test.@testset($(args...)))) # TODO
    desc, testsettype, options = Test.parse_testset_args(args[1:end-1])
    return checked_ts_expr(desc, ts_expr)
    # return :($(Expr(:block, prolog, ts_expr)))
end

partial(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS | Base.PCRE.PARTIAL_HARD)

exact(str::AbstractString) = Regex(str, Base.DEFAULT_COMPILER_OPTS,
    Base.DEFAULT_MATCH_OPTS)

function runtests(fun::Function, args...)
    includes = []
    excludes = ["(?!)"]     # seed with an unsatisfiable regex
    for arg in args
        if startswith(arg, "-") || startswith(arg, "¬")
            push!(excludes, arg[nextind(arg,1):end])
        else
            push!(includes, arg)
        end
    end
    include = partial(join(includes, "|"))
    exclude = exact(join(excludes, "|"))
    state = TestyState(Vector{String}(), include, exclude)
    task_local_storage(:__TESTY_STATE__, state)
    fun()
    state
end

function showtests(args...)
end

export @testset, @test_broken
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
