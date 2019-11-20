import DFControl: Projection, Orbital, Structure, orbital, size, orbsize, dfprintln, dfprint

import DFControl.Crayons: @crayon_str

uniform_shifted_kgrid(::Type{T}, nkx::Integer, nky::Integer, nkz::Integer) where {T} =
	[Vec3{T}(kx, ky, kz) for kx = 0.5/nkx:1/nkx:1, ky = 0.5/nky:1/nky:1, kz = 0.5/nkz:1/nkz:1]

uniform_shifted_kgrid(nkx::Integer, nky::Integer, nkz::Integer) = uniform_shifted_kgrid(Float64, nkx, nky, nkz)

setup_ω_grid(ωh, ωv, n_ωh, n_ωv, offset=0.001) = vcat(range(ωh,             ωh + ωv*1im,     length=n_ωv)[1:end-1],
											         range(ωh + ωv*1im,     offset + ωv*1im, length=n_ωh)[1:end-1],
											         range(offset + ωv*1im, offset,          length=n_ωv))

struct KPoint{T<:AbstractFloat,MT<:AbstractMatrix{Complex{T}}}
	k_cryst ::Vec3{T}
	phase   ::Complex{T}
	eigvals ::Vector{T}
	eigvecs ::MT
end

KPoint(k::Vec3{T}, dims::NTuple{2, Int}, R=zero(Vec3{T}), vecmat=zeros(Complex{T}, dims)) where {T} =
	KPoint(k, exp(2im * π * dot(R, k)), zeros(T, max(dims...)), vecmat)

@doc raw"""
	fill_kgrid(hami::TbHami{T}, R, nk, Hfunc::Function = x -> nothing) where T
	fill_kgrid(hami::TbHami{T}, R, k_grid, Hfunc::Function = x -> nothing) where T

Generates a grid of `KPoint`s and fills them with the diagonalized hamiltonians and phases.
An extra function Hfunc can be passed which will be run on every $H(k)$ like `Hfunc(Hk)`.
"""
function fill_kgrid(hami::TbHami{T}, k_grid, R=zero(Vec3{T}), Hfunc::Function = x -> nothing) where T
	kpoints = [KPoint(k, blocksize(hami), R, zeros_block(hami)) for k in k_grid]
	nk    = length(kpoints)
	calc_caches = [EigCache(block(hami[1])) for i=1:nthreads()]
    @threads for i=1:nk
	    tid = threadid()
	    kp = kpoints[i]
	    cache = calc_caches[tid]
	    #= kp.eigvecs is used as a temporary cache to store H(k) in. Since we
	    don't need H(k) but only Hvecs etc, this is ok.
	    =#
	    Hk!(kp, hami)
	    Hfunc(kp.eigvecs)
	    eigen!(kp.eigvals, kp.eigvecs, cache)
    end
    return kpoints
end

function fill_kgrid(hami::TbHami{T}, nk::NTuple{3, Int}, R=zero(Vec3{T}), Hfunc::Function = x -> nothing) where T
    k_grid  = uniform_shifted_kgrid(nk...)
    return fill_kgrid(hami, k_grid, R, Hfunc)
end

@doc raw"""
	fill_kgrid_D(hami::TbHami{T}, nk, R=zero(Vec3{T})) where T

Generates kpoints with `fill_kgrid` and calculates $D(k) = [H(k), J]$, $P(k)$ and $L(k)$ where $H(k) = P(k) L(k) P^{-1}(k)$.
"""
function fill_kgrid_D(hami::TbHami{T}, nk, R=zero(Vec3{T})) where T
    D     = ThreadCache(zeros_block(hami))
    kpoints = fill_kgrid(hami, nk, R, x -> D .+= x)
	Ds = gather(D)
    return kpoints, (Ds[Up()] - Ds[Down()])/prod(nk)
end

function Hk!(kpoint::KPoint{T}, tbhami::TbHami{T, M}) where {T, M <: AbstractMatrix{Complex{T}}}
    for b in tbhami
	    fac = ℯ^(-2im*pi*(b.R_cryst ⋅ kpoint.k_cryst))
        Hk_sum!(kpoint.eigvecs, block(b), fac)
    end
end

struct ColinGreensFunction{T<:AbstractFloat}
	ω::T
	G::ColinMatrix{Complex{T}} #forward part is always spin up, backward spin down
end

function calc_greens_functions(ω_grid, kpoints, μ::T) where T
    g_caches = [ThreadCache(fill!(similar(kpoints[1].eigvecs), zero(Complex{T}))) for i=1:3]
    Gs = [fill!(similar(kpoints[1].eigvecs), zero(Complex{T})) for i = 1:length(ω_grid)-1]
    function iGk!(G, ω)
	    fill!(G, zero(Complex{T}))
        integrate_Gk!(G, ω, μ, kpoints, cache.(g_caches))
    end

    @threads for j=1:length(ω_grid) - 1
        ω   = ω_grid[j]
        dω  = ω_grid[j + 1] - ω
        iGk!(Gs[j], ω)
    end
    return Gs
end

function integrate_Gk!(G::AbstractMatrix, ω, μ, kpoints, caches)
    dim = size(G, 1)
	cache1, cache2, cache3 = caches

	b_ranges = [1:dim, 1:dim]
    @inbounds for ik=1:length(kpoints)
	    # Fill here needs to be done because cache1 gets reused for the final result too
        fill!(cache1, zero(eltype(cache1)))
        for x=1:dim
            cache1[x, x] = 1.0 /(μ + ω - kpoints[ik].eigvals[x])
        end
     	# Basically Hvecs[ik] * 1/(ω - eigvals[ik]) * Hvecs[ik]'

        mul!(cache2, kpoints[ik].eigvecs, cache1)
        adjoint!(cache3, kpoints[ik].eigvecs)
        mul!(cache1, cache2, cache3)
		t = kpoints[ik].phase
		tp = t'
        for i in 1:dim, j in 1:dim
            G[i, j]     += cache1[i, j] * t
        end
    end
    G  ./= length(kpoints)
end

function integrate_Gk!(G::ColinMatrix, ω, μ, kpoints, caches)
    dim = size(G, 1)
	cache1, cache2, cache3 = caches

	b_ranges = [1:dim, dim+1:2dim]
    @inbounds for ik=1:length(kpoints)
	    # Fill here needs to be done because cache1 gets reused for the final result too
        fill!(cache1, zero(eltype(cache1)))
        for x=1:dim
            cache1[x, x] = 1.0 /(μ + ω - kpoints[ik].eigvals[x])
            cache1[x, x+dim] = 1.0 /(μ + ω - kpoints[ik].eigvals[x+dim])
        end
     	# Basically Hvecs[ik] * 1/(ω - eigvals[ik]) * Hvecs[ik]'

        mul!(cache2, kpoints[ik].eigvecs, cache1)
        adjoint!(cache3, kpoints[ik].eigvecs)
        mul!(cache1, cache2, cache3)
		t = kpoints[ik].phase
		tp = t'
        for i in 1:dim, j in 1:dim
            G[i, j]     += cache1[i, j] * t
            G[i, j+dim] += cache1[i, j+dim] * tp
        end
    end
    G  ./= length(kpoints)
end

function integrate_Gk!(G_forward::ThreadCache, G_backward::ThreadCache, ω, μ, Hvecs, Hvals, R, kgrid, caches)
    dim = size(G_forward, 1)
	cache1, cache2, cache3 = caches

    @inbounds for ik=1:length(kgrid)
	    # Fill here needs to be done because cache1 gets reused for the final result too
        fill!(cache1, zero(eltype(cache1)))
        for x=1:dim
            cache1[x, x] = 1.0 /(μ + ω - Hvals[ik][x])
        end
     	# Basically Hvecs[ik] * 1/(ω - eigvals[ik]) * Hvecs[ik]'
        mul!(cache2, Hvecs[ik], cache1)
        adjoint!(cache3, Hvecs[ik])
        mul!(cache1, cache2, cache3)
		t = exp(2im * π * dot(R, kgrid[ik]))
        G_forward  .+= cache1 .* t
        G_backward .+= cache1 .* t'
    end
    G_forward.caches  ./= length(kgrid)
    G_backward.caches ./= length(kgrid)
end

abstract type Exchange{T<:AbstractFloat} end

function (::Type{E})(at1::AbstractAtom{T}, at2::AbstractAtom{T}; site_diagonal::Bool=false) where {E<:Exchange,T}
    l1 = length(range(at1))
    l2 = length(range(at2))
    return site_diagonal ? E{T}(zeros(T, l1, l2), at1, at2) : E{T}(zeros(T, l1, l1), at1, at2)
end
"""
    Exchange2ndOrder{T <: AbstractFloat}

This holds the exhanges between different orbitals and calculated sites.
Projections and atom datablocks are to be found in the corresponding wannier input file.
It turns out the ordering is first projections, then atom order in the atoms datablock.
"""
mutable struct Exchange2ndOrder{T <: AbstractFloat} <: Exchange{T}
    J       ::Matrix{T}
    atom1   ::Atom{T}
    atom2   ::Atom{T}
end

function Base.show(io::IO, e::Exchange)
	dfprint(io, crayon"red", "atom1:", crayon"reset")
	dfprintln(io,"name: $(name(e.atom1)), pos: $(position_cryst(e.atom1))")
	dfprint(io, crayon"red", " atom2:", crayon"reset")
	dfprintln(io,"name: $(name(e.atom2)), pos: $(position_cryst(e.atom2))")

	dfprint(io, crayon"red", " J: ", crayon"reset", "$(e.J)")
end

"""
    Exchange4thOrder{T <: AbstractFloat}

This holds the exhanges between different orbitals and calculated sites.
Projections and atom datablocks are to be found in the corresponding wannier input file.
It turns out the ordering is first projections, then atom order in the atoms datablock.
"""
mutable struct Exchange4thOrder{T <: AbstractFloat} <: Exchange{T}
    J       ::Matrix{T}
    atom1   ::Atom{T}
    atom2   ::Atom{T}
end

function calc_exchanges(hami,  atoms, fermi::T, ::Type{E}=Exchange2ndOrder;
                        nk::NTuple{3, Int} = (10, 10, 10),
                        R                  = Vec3(0, 0, 0),
                        ωh::T              = T(-30.), #starting energy
                        ωv::T              = T(0.15), #height of vertical contour
                        n_ωh::Int          = 3000,
                        n_ωv::Int          = 500,
                        temp::T            = T(0.01),
                        site_diagonal      = false) where {T<:AbstractFloat, E<:Exchange}

    μ               = fermi
    ω_grid          = setup_ω_grid(ωh, ωv, n_ωh, n_ωv)
    
    exchanges       = E{T}[]
    for (i, at1) in enumerate(atoms), at2 in atoms[i:end]
	    push!(exchanges, E(at1, at2, site_diagonal=site_diagonal))
    end

    kpoints, D = fill_kgrid_D(hami, nk, R)

    D_ = site_diagonal ? site_diagonalize(D, atoms) : D
    calc_exchanges!(exchanges, μ, ω_grid, kpoints, D_)

    return exchanges
end

function site_diagonalize(D::Matrix{Complex{T}}, ats::Vector{<:DFC.AbstractAtom}) where {T}
	Ts = zeros(D)
	Dvals = zeros(T, size(D, 1))
	for at in ats
		t_vals, t_vecs = eigen(Hermitian(D[at]))
		Ts[at] .= t_vecs
		Dvals[range(at)] .=  real.(t_vals)
	end
	return SiteDiagonalD(Dvals, Ts)
end

function calc_exchanges!(exchanges::Vector{<:Exchange{T}},
	                                 μ         ::T,
	                                 ω_grid    ::AbstractArray{Complex{T}},
	                                 kpoints  ,
	                                 D         ::Union{Matrix{Complex{T}}, SiteDiagonalD{T}}) where T <: AbstractFloat
    dim     = size(kpoints[1].eigvecs)
    d2      = div(dim[1], 2)
    J_caches = [ThreadCache(zeros(T, size(e.J))) for e in exchanges]
	Gs = calc_greens_functions(ω_grid, kpoints, μ)
	@threads for i =1:length(Gs)
        for (eid, exch) in enumerate(exchanges)
            J_caches[eid] .+= Jω(exch, D, Gs[i], ω_grid[i+1]-ω_grid[i])
        end
    end
    for (eid, exch) in enumerate(exchanges)
        exch.J = -1e3 / 2π * gather(J_caches[eid])
    end
end

spin_sign(D) = -sign(real(tr(D))) #up = +1, down = -1. If D_upup > D_dndn, onsite spin will be down and the tr(D) will be positive. Thus explaining the - in front of this.
spin_sign(D::Vector) = sign(real(sum(D))) #up = +1, down = -1

perturbation_loop(exch::Exchange2ndOrder, D_site1, G_forward, D_site2, G_backward) =
	D_site1 * G_forward * D_site2 * G_backward

perturbation_loop(exch::Exchange4thOrder, D_site1, G_forward, D_site2, G_backward) =
	D_site1 * G_forward * D_site2 * G_backward * D_site1 * G_forward * D_site2 * G_backward

@inline function Jω(exch, D, G, dω)
    D_site1    = view(D, exch.atom1)
    D_site2    = view(D, exch.atom2)
    G_forward  = view(G, exch.atom1, exch.atom2, Up())
    G_backward = view(G, exch.atom2, exch.atom1, Down())
	return spin_sign(D_site1) .* spin_sign(D_site2) .* imag.(perturbation_loop(exch,
																			   D_site1,
																			   G_forward,
																			   D_site2,
																			   G_backward) * dω)
end

@inline function Jω(exch, D::SiteDiagonalD, G, dω)
	s1 = spin_sign(D.values[exch.atom1])
	s2 = spin_sign(D.values[exch.atom2])
	t  = zeros(exch.J)
	G_forward  = D.T[exch.atom1]' * G[exch.atom1, exch.atom2, Up()] * D.T[exch.atom2]
	G_backward = D.T[exch.atom2]' * G[exch.atom2, exch.atom1, Down()] *  D.T[exch.atom1]
	for j=1:size(t, 2), i=1:size(t, 1)
		t[i, j] = s1 * s2 * imag(D.values[exch.atom1][i] * G_forward[i, j] * D.values[exch.atom2][j] * G_backward[j, i] * dω)
	end
	return t  
end

mutable struct AnisotropicExchange2ndOrder{T <: AbstractFloat} <: Exchange{T}
    J     ::Matrix{Matrix{T}}
    atom1 ::Atom{T}
    atom2 ::Atom{T}
end

AnisotropicExchange2ndOrder(at1::AbstractAtom{T}, at2::AbstractAtom{T}) where {T} =
	AnisotropicExchange2ndOrder{T}([zeros(T, length(range(at1)), length(range(at1))) for i=1:3,j=1:3], atom(at1), atom(at2))

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
    exchanges       = setup_anisotropic_exchanges(atoms)

    Hvecs, Hvals, D = DHvecvals(hami, k_grid, atoms)
    # @show D

    calc_anisotropic_exchanges!(exchanges, μ, R, k_grid, ω_grid, Hvecs, Hvals, D)
    return exchanges
end

function calc_anisotropic_exchanges!(exchanges ::Vector{AnisotropicExchange2ndOrder{T}}, 
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
 
    function iGk!(ω) 
      fill!(G_forward, zero(Complex{T})) 
      fill!(G_backward, zero(Complex{T})) 
        integrate_Gk!(G_forward, G_backward, ω, μ, Hvecs, Hvals, R, k_grid, g_caches) 
    end 
 
    for j=1:length(ω_grid[1:end-1]) 
        ω   = ω_grid[j] 
        dω  = ω_grid[j + 1] - ω 
        iGk!(ω) 
    # The two kind of ranges are needed because we calculate D only for the projections we care about 
    # whereas G is calculated from the full Hamiltonian, the is needed. 
        for (eid, exch) in enumerate(exchanges) 
            rm  = range(exch.atom1) 
            rn  = range(exch.atom2) 
      for i =1:3, j=1:3 #x,y,z 
              J_caches[eid][i, j] .+=  imag.((view(D[eid][i], 1:length(rm), 1:length(rm)) * 
                                  view(G_forward, rm, rn)    * 
                                  view(D[eid][j], 1:length(rn), 1:length(rn))  * 
                                  view(G_backward, rn, rm)) .* dω) 
            end 
        end 
    end 
 
    for (eid, exch) in enumerate(exchanges) 
        exch.J = 1e3 / 2π * gather(J_caches[eid]) 
    end 
end

function setup_anisotropic_exchanges(atoms::Vector{<: AbstractAtom{T}}) where T <: AbstractFloat
    exchanges = AnisotropicExchange2ndOrder{T}[]
    for (i, at1) in enumerate(atoms), at2 in atoms[i:end]
            push!(exchanges, AnisotropicExchange2ndOrder(at1, at2))
    end
    return exchanges
end

@doc raw"""
	DHvecvals(hami::TbHami{T, Matrix{T}}, k_grid::Vector{Vec3{T}}, atoms::AbstractAtom{T}) where T <: AbstractFloat


Calculates $D(k) = [H(k), J]$, $P(k)$ and $L(k)$ where $H(k) = P(k) L(k) P^{-1}(k)$.
`hami` should be the full Hamiltonian containing both spin-diagonal and off-diagonal blocks.
"""
function DHvecvals(hami, k_grid::AbstractArray{Vec3{T}}, atoms::Vector{WanAtom{T}}) where T <: AbstractFloat

	nk        = length(k_grid)
    Hvecs     = [zeros_block(hami) for i=1:nk]
    Hvals     = [Vector{T}(undef, blocksize(hami, 1)) for i=1:nk]
    δH_onsite = ThreadCache([[zeros(Complex{T}, 2length(range(at)), 2length(range(at))) for i=1:3] for at in atoms])
	calc_caches = [EigCache(block(hami[1])) for i=1:nthreads()]
    for i=1:nk
    # for i=1:nk
	    tid = threadid()
        # Hvecs[i] is used as a temporary cache to store H(k) in. Since we
        # don't need H(k) but only Hvecs etc, this is ok.
        Hk!(Hvecs[i], hami, k_grid[i])

        for (δh, at) in zip(δH_onsite, atoms)
	        rat = range(at)
	        lr  = length(rat)
        	δh .+= commutator.((view(Hvecs[i], rat, rat),), at[:operator_block].J) #in reality this should be just range(at)
        	# δh .+= commutator.(([Hvecs[i][rat, rat] zeros(Complex{T},lr, lr); zeros(Complex{T}, lr, lr) Hvecs[i][div(blocksize(hami, 1), 2) .+ rat, div(blocksize(hami, 1), 2) .+ rat]],), at[:operator_block].J) #in reality this should be just range(at)
        end
        eigen!(Hvals[i], Hvecs[i], calc_caches[tid])
    end
    return Hvecs, Hvals, gather(δH_onsite)./nk
end

commutator(A1, A2) where T = A1*A2 - A2*A1
 
function totocc(Hvals, fermi::T, temp::T) where T
    totocc = zero(Complex{T})
    for i = 1:length(Hvals)
        totocc += gather( 1 ./ (exp.((Hvals[i] .- fermi)./temp) .+ 1))
    end
    return totocc/length(Hvals)
end

"Generates a Pauli σx matrix with the dimension that is passed through `n`."
σx(::Type{T}, n::Int) where {T} =
	kron(Mat2([0 1; 1 0]), diagm(0 => ones(T, div(n, 2))))

"Generates a Pauli σy matrix with the dimension that is passed through `n`."
σy(::Type{T}, n::Int) where {T} =
	kron(Mat2([0 -1im; 1im 0]), diagm(0 => ones(T, div(n, 2))))

"Generates a Pauli σz matrix with the dimension that is passed through `n`."
σz(::Type{T}, n::Int) where {T} =
	kron(Mat2([1 0; 0 -1]), diagm(0 => ones(T, div(n, 2))))

for s in (:σx, :σy, :σz)
	@eval @inline $s(m::AbstractArray{T}) where {T} =
		$s(T, size(m, 1))
	@eval $s(m::TbHami) = $s(block(m[1]))
end

σx(m::ColinMatrix{T}) where {T} =
	zeros(m)

σy(m::ColinMatrix{T}) where {T} =
	zeros(m)

σz(m::ColinMatrix{T}) where {T} =
	ColinMatrix(diagm(0 => ones(T, size(m, 1))), diagm(0 => -1.0 .* ones(T, size(m, 1))))

function calc_onsite_spin(kpoints::AbstractArray{<:KPoint{T}}, atom, fermi=0.0) where {T}
	S = Vec3(σx(kpoints[1].eigvecs[atom]),
	         σy(kpoints[1].eigvecs[atom]),
	         σz(kpoints[1].eigvecs[atom]))

	S_out = zero(Vec3{T})
	for k in kpoints
		for (i, v) in enumerate(k.eigvals)
			if i - fermi <= 0.0
				vec = k.eigvecs[:, i][atom]
			    S_out += real((vec',) .* S .* (vec,))
			end
		end
	end
	return S_out./length(kpoints)
end

