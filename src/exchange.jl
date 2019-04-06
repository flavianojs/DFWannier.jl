using DFControl: Projection, Orbital, Structure, orbital, size, orbsize
"""
    WannExchanges{T <: AbstractFloat}

This holds the exhanges between different orbitals and calculated sites.
Projections and atom datablocks are to be found in the corresponding wannier input file.
It turns out the ordering is first projections, then atom order in the atoms datablock.
"""
mutable struct Exchange{T <: AbstractFloat}
    J       ::Matrix{T}
    atom1   ::Atom{T}
    atom2   ::Atom{T}
    proj1   ::Projection
    proj2   ::Projection
end

function DHvecvals(hamis, k_grid)
    Hvecs = [[similar(hami[1].block) for i=1:length(k_grid)] for hami in hamis]
    Hvals = [[similar(hami[1].block[:,1]) for i=1:length(k_grid)] for hami in hamis]
    D    = [zeros(eltype(hamis[1][1].block), size(hamis[1][1].block)) for i=1:Threads.nthreads()]
    Threads.@threads for i=1:length(k_grid)
        for j=1:2
            fac = (-1)^(j - 1)
            tid = Threads.threadid()
            #= Hvecs[j][i] is used as a temporary cache to store H(k) in. Since we
            don't need H(k) but only Hvecs etc, this is ok.
            =#
            Hk!(Hvecs[j][i], hamis[j], k_grid[i])
            D[tid] .+= fac .* Hvecs[j][i]
            Hvals[j][i], Hvecs[j][i] = LAPACK.syevr!('V', 'A', 'U', Hvecs[j][i], 0.0, 0.0, 0, 0, -1.0)
        end
    end
    return Hvecs, Hvals, sum(D)/length(k_grid)
end

function setup_exchanges(atoms::Vector{<:AbstractAtom{T}}, orbitals) where T <: AbstractFloat
    exchanges = Exchange{T}[]
    for (i, at1) in enumerate(atoms), at2 in atoms
        for proj1 in projections(at1), proj2 in projections(at2)
            if proj1.orb in orbitals && proj2.orb in orbitals
                push!(exchanges, Exchange{T}(zeros(T, orbsize(proj1), orbsize(proj1)), at1, at2, proj1, proj2))
            end
        end
    end
    return exchanges
end

function setup_ω_grid(ωh, ωv, n_ωh, n_ωv, offset=0.00)
    ω_grid = vcat(range(ωh, stop=ωh + ωv*1im, length=n_ωv)[1:end-1],
                  range(ωh + ωv*1im, stop=offset + ωv*1im, length=n_ωh)[1:end-1],
                  range(offset + ωv*1im, stop=offset, length=n_ωv))
    return ω_grid
end


#DON'T FORGET HAMIS ARE UP DOWN ORDERED!!!
function calcexchanges(hamis,  structure::Structure, fermi::T;
                             nk::NTuple{3, Int} = (10, 10, 10),
                             R                  = Vec3(0, 0, 0),
                             ωh::T              = T(-30.), #starting energy
                             ωv::T              = T(0.1), #height of vertical contour
                             n_ωh::Int          = 300,
                             n_ωv::Int          = 50,
                             temp::T            = T(0.01),
                             orbitals::Array{Symbol, 1} = [:d, :f]) where T <: AbstractFloat
    orbitals = orbital.(orbitals)
    @assert !all(isempty.(projections.(DFControl.atoms(structure)))) "Please read a valid wannier file for structure with projections."
    nth      = Threads.nthreads()
    μ        = fermi
    atoms    = structure.atoms
    k_grid   = [Vec3(kx, ky, kz) for kx = 0.5/nk[1]:1/nk[1]:1, ky = 0.5/nk[2]:1/nk[2]:1, kz = 0.5/nk[3]:1/nk[3]:1]

    Hvecs, Hvals, D = DHvecvals(hamis, k_grid)
    n_orb = size(D)[1]

    ω_grid    = setup_ω_grid(ωh, ωv, n_ωh, n_ωv)
    exchanges = setup_exchanges(atoms, orbitals)

    t_js                      = [[zeros(T, size(e.J)) for t=1:nth] for e in exchanges]
    caches1, caches2, caches3 = [[zeros(Complex{T}, n_orb, n_orb) for t=1:nth] for i=1:3]
    totocc_t                  = [zero(Complex{T}) for t=1:nth]
    gs                        = [[zeros(Complex{T}, n_orb, n_orb) for n=1:2] for t  =1:nth]
    # Threads.@threads for j=1:length(ω_grid[1:end-1])
    Threads.@threads for j=1:length(ω_grid[1:end-1])
        tid = Threads.threadid()
        ω   = ω_grid[j]
        dω  = ω_grid[j + 1] - ω
        g   = gs[tid]
        for s = 1:2
            R_ = (-1)^(s-1) * R #R for spin up (-1)^(0) == 1, -R for spin down
            G!(g[s], caches1[tid], caches2[tid], caches3[tid], ω, μ, Hvecs[s], Hvals[s], R_, k_grid)
        end
        for (eid, exch) in enumerate(exchanges)
            rm = range(exch.proj1)
            rn = range(exch.proj2)
            t_js[eid][tid] .+= sign(real(tr(view(D, rm, rm)))) .* sign(real(tr(view(D,rn, rn)))) .* imag(view(D,rm, rm) * view(g[1],rm, rn) * view(D,rn, rn) * view(g[2],rn, rm) * dω)
        end
    end
    for (eid, exch) in enumerate(exchanges)
        exch.J = 1e3 / (2π * length(k_grid)^2) * sum(t_js[eid])
    end
    structure.data[:totocc] = real(totocc(Hvals, fermi, temp))
    structure.data[:exchanges] = exchanges
end

mutable struct AnisotropicExchange{T <: AbstractFloat}
    J       ::Matrix{Matrix{T}}
    atom1   ::Atom{T}
    atom2   ::Atom{T}
    proj1   ::Projection
    proj2   ::Projection
end

commutator(A1, A2) where T = A1*A2 - A2*A1

 

function DHvecvals(hami::TbHami{T}, k_grid, atoms) where T
	# Get all the projections that we care about, basically the indices of the hami blocks.
	all_projections = Projection[]
	append!.((all_projections,), projections.(atoms))

	# Get all J matrices corresponding to the projections
	all_Js = Vector{Matrix{Complex{T}}}[]
	for at in atoms
		for b in at[:operator_blocks]
			push!(all_Js, b.J)
		end
	end

	nk        = length(k_grid)
    Hvecs     = [empty_block(hami) for i=1:nk]
    Hvals     = [Vector{T}(undef, blockdim(hami)[1]) for i=1:nk]
    δH_onsite = ThreadCache([[zeros(Complex{T}, orbsize(projection), orbsize(projection)) for i=1:3] for projection in all_projections])
    @threads for i=1:nk
    # for i=1:nk
            # Hvecs[i] is used as a temporary cache to store H(k) in. Since we
            # don't need H(k) but only Hvecs etc, this is ok.
            
        Hk!(Hvecs[i], hami, k_grid[i])

        # for each of the dh block, proj block and J combo we have to add it to the variation of onsite hami
        for (δh, projection, j) in zip(δH_onsite, all_projections, all_Js) 
	        δh .+= commutator.((view(Hvecs[i], range(projection), range(projection)),), j)
        end
        Hvals[i], Hvecs[i] = LAPACK.syevr!('V', 'A', 'U', Hvecs[i], 0.0, 0.0, 0, 0, -1.0)
    end
    return Hvecs, Hvals, sum(δH_onsite.caches)./nk
end

function setup_anisotropic_exchanges(atoms::Vector{<:AbstractAtom{T}}) where T <: AbstractFloat
    exchanges = AnisotropicExchange{T}[]
    for (i, at1) in enumerate(atoms), at2 in atoms[i+1:end]
        for proj1 in projections(at1), proj2 in projections(at2)
            push!(exchanges, AnisotropicExchange{T}([zeros(T, orbsize(proj1), orbsize(proj1)) for i=1:3, j=1:3], at1.atom, at2.atom, proj1, proj2))
        end
    end
    return exchanges
end

uniform_shifted_kgrid(nkx, nky, nkz) = [Vec3(kx, ky, kz) for kx = 0.5/nkx:1/nkx:1, ky = 0.5/nky:1/nky:1, kz = 0.5/nkz:1/nkz:1]

function calc_anisotropic_exchanges(hami,  atoms, fermi::T;
                             nk::NTuple{3, Int} = (10, 10, 10),
                             R                  = Vec3(0, 0, 0),
                             ωh::T              = T(-30.), #starting energy
                             ωv::T              = T(0.1), #height of vertical contour
                             n_ωh::Int          = 3000,
                             n_ωv::Int          = 500,
                             temp::T            = T(0.01)) where T <: AbstractFloat

    μ               = fermi
    k_grid          = uniform_shifted_kgrid(nk...)
    ω_grid          = setup_ω_grid(ωh, ωv, n_ωh, n_ωv)

    Hvecs, Hvals, D = DHvecvals(hami, k_grid, atoms)
    exchanges       = setup_anisotropic_exchanges(atoms)

    calc_anisotropic_exchanges!(exchanges, μ, R, k_grid, ω_grid, Hvecs, Hvals, D)
    return exchanges
end

function integrate_Gk!(G_forward, G_backward, ω::T, μ, Hvecs, Hvals, R, kgrid, caches) where T
    dim = size(G_forward)[1]
	cache1, cache2, cache3 = caches
    fill!(G_forward, zero(T))
    fill!(G_backward, zero(T))

    for ik=1:length(kgrid)
        fill!(cache1, zero(T))
        for x=1:dim
            cache1[x, x] = 1.0 /(μ + ω - Hvals[ik][x])
        end
        @! cache2 = Hvecs[ik] * cache1
        adjoint!(cache3, Hvecs[ik])
        @! cache1 = cache2 * cache3
        G_forward.caches[threadid()]  .+= cache1 .* exp(2im * π * dot(R, kgrid[ik]))
        G_backward.caches[threadid()] .+= cache1 .* exp(2im * π * dot(R, kgrid[ik]))
    end
end

function calc_anisotropic_exchanges!(exchanges ::Vector{AnisotropicExchange{T}},
	                                 μ         ::T,
	                                 R         ::Vec3,
	                                 k_grid    ::AbstractArray{Vec3{T}},
	                                 ω_grid    ::AbstractArray{Complex{T}},
	                                 Hvecs     ::Vector{Matrix{Complex{T}}},
	                                 Hvals     ::Vector{Vector{T}},
	                                 D         ::Vector{Vector{Matrix{Complex{T}}}}) where T <: AbstractFloat
    dim      = size(Hvecs[1])
    J_caches = [ThreadCache([zeros(T, size(e.J[i, j])) for i=1:3, j=1:3]) for e in exchanges]
    g_caches = [ThreadCache(zeros(Complex{T}, dim)) for i=1:3]
    G_forward, G_backward = [ThreadCache(zeros(Complex{T}, dim)) for i=1:2]

    iGk!(ω) = integrate_Gk!(G_forward,
						    G_backward,
						    ω,
						    μ,
						    Hvecs,
						    Hvals,
						    R,
						    k_grid,
						    g_caches)

    @threads for j=1:length(ω_grid[1:end-1])
        ω   = ω_grid[j]
        dω  = ω_grid[j + 1] - ω

        iGk!(ω)

        for (eid, exch) in enumerate(exchanges)
            rm = range(exch.proj1)
            rn = range(exch.proj2)
            drm = 1:orbsize(exch.proj1)
            drn = 1:orbsize(exch.proj2)
			for i =1:3, j=1:3
	            J_caches[eid][i, j] .+=  imag(view(D[eid][i], drm, drm) *
	            					          view(G_forward, rm, rn) *
	            					          view(D[eid][j], drn, drn) *
	            					          view(G_backward, rn, rm) * dω)
            end
        end
    end

    for (eid, exch) in enumerate(exchanges)
        exch.J = 1e3 / (2π * length(k_grid)^2) * sum(J_caches[eid])
    end
end

function totocc(Hvals, fermi::T, temp::T) where T
    totocc = zero(Complex{T})
    for s=1:2
        for i = 1:length(Hvals[s])
            totocc += sum( 1 ./ (exp.((Hvals[s][i].-fermi)./temp) .+ 1))
        end
    end
    return totocc/length(Hvals[1])
end
