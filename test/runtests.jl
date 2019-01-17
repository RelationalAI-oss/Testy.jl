using Testy

function test()
    for ch in ["a","b","c"]
        @testset "$ch" begin
            @test 1==1
            for i in 1:3
                @testset "$i" begin
                    @test 1==1
                    @test_broken 0==1
                end
            end
        end
    end
end

function case(str, test, args...)
    println(str)
    println("======")
    runtests(test, args...)
    println()
end

case("Run all tests", test)

case("Run everything under 'a'", test, "a/.*")

# "Run 'a/2'"
case("Run 'a/2'", test, "a/2")

# "Run 'a/2' and 'b/3'"
case("Run 'a/2' and 'b/3'", test, "a/2", "b/3")

# "Run all except 'b/2' and 'b/3'"
case("Run all except 'b/2' and 'b/3'", test, "¬b/2", "-b/3")

# "Print names of all test sets"
showtests(test)

# "Print names of all test sets except 'b'"
showtests(test, "", "¬b/.*")
