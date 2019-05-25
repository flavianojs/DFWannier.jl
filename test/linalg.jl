
for F in (Float32, Float64)
	t = rand(Complex{F}, 50, 50)
	orig       = (t + t')/2
	normal_eig = eigen(orig)
	cache      = DFW.EigCache(orig)
	cached_eig = eigen(orig, cache)
	@test sum(normal_eig.values) ≈ sum(cached_eig.values) 
	@test Array(normal_eig) ≈ Array(cached_eig) ≈ orig
end

for F in (Float32, Float64)
	t = rand(Complex{F}, 50, 50)
	orig       = DFW.BlockBandedMatrix((t + t')/2, ([25, 25], [25, 25]), (0, 0))
	normal_eig1, normal_eig2 = eigen(orig[DFW.Block(1,1)]), eigen(orig[DFW.Block(2,2)])
	cache      = DFW.EigCache(orig)
	cached_eig = eigen(orig, cache)
	@test sum(normal_eig1.values) + sum(normal_eig2.values) ≈ sum(cached_eig.values)
	@test Array(normal_eig1) ≈ Array(cached_eig)[1:25, 1:25] ≈ orig[DFW.Block(1, 1)]
	@test Array(normal_eig2) ≈ Array(cached_eig)[26:50, 26:50] ≈ orig[DFW.Block(2, 2)]
end

