module Runtests

using Testy

function test()
    @testsuite "t" for ch in ["a","b","c"]
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

test()

end
