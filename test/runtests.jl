module Runtests

using Testy

function closure(expected::Vector{String})
    cl = Set{String}()
    for path in expected
        segs = split(path, "/")
        s = ""
        first = true
        for seg in segs
            if first
                s = seg
                first = false
            else
                s = s*"/"*seg
            end
            push!(cl, s)
        end
    end
    sort(collect(cl))
end

function case(str::String, expected::Vector{String}, args...)
    @testset "$str" begin
        state = runtests(args...; filename="runtests2.jl")
        seen = sort(collect(map(kv -> kv[1], filter(kv -> kv[2], state.seen))))
        expected = sort(closure(expected))
        @test seen == expected
    end
end

@testsuite "Testy" begin
    @testset "List top-level test sets" begin
        seen = showtests("runtests2.jl")
        @test sort(seen) == [ "t", "t/a", "t/b", "t/c" ]
    end

    case("Run all tests",
        [ "t/a/1", "t/a/2", "t/a/3",
          "t/b/1", "t/b/2", "t/b/3",
          "t/c/1", "t/c/2", "t/c/3" ]
    )

    case("Run everything under 't/a'",
        [ "t/a/1", "t/a/2", "t/a/3" ],
         "t/a/.*"
    )

    # "Run 'a/2'"
    case("Run 't/a/2'",
        [ "t/a/2" ],
         "t/a/2")

    # "Run 'a/2' and 'b/3'"
    case("Run 't/a/2' and 't/b/3'",
        [ "t/a/2", "t/b/3" ],
        "t/a/2", "t/b/3")

    # "Run all except 'b/2' and 'b/3'"
    case("Run all except 't/b/2' and 't/b/3'",
        [ "t/a/1", "t/a/2", "t/a/3",
          "t/b/1",
          "t/c/1", "t/c/2", "t/c/3" ],
        "!t/b/2", "!t/b/3")
end

end
