module Runtests

using Testy

# function test()
#     @testsuite "t" for ch in ["a","b","c"]
#         @testset "$ch" begin
#             @test 1==1
#             for i in 1:3
#                 @testset "$i" begin
#                     @test 1==1
#                     @test_broken 0==1
#                 end
#             end
#         end
#         @testset "d"
#             @test 0==1
#         end
#     end
# end
#
# test()

@testsuite "foo" for ch in [1,2,3]
    @testset "bar" begin
        @test 1==1
    end
end

end
