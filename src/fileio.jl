import DFControl: searchdir
#does this really need the checking for corruption stuff?
function read_xsf_header(::Type{T}, filename::String) where T
    open(filename) do f
        nx, ny, nz = 0, 0, 0
        origin     = zero(Point3{T})
        supercell  = zero(Mat3{T})
        read_split_parse(typ) = parse.(typ, split(readline(f)))
        lines = 0
        while true
            lines += 1
            line = readline(f)
            if line == "BEGIN_DATAGRID_3D_UNKNOWN"
                nx, ny, nz = read_split_parse(Int)
                origin     = Point3{T}(read_split_parse(T))
                t = collect(hcat([read_split_parse(T) for i=1:3]...)')::Matrix{T}
                supercell  = Mat3{T}(t)
                lines += 1 + 1 + 3
                break
            end
        end
        return nx, ny, nz, origin, supercell, lines
    end
end

function read_points_from_xsf(::Type{T}, filename::String) where {T <: AbstractFloat}
    open(filename) do f
        while !eof(f)
            line = readline(f)
            if line == " DATAGRID_3D_DENSITY" ||
               occursin("DATAGRID_3D_UNKNOWN", line)

                nx, ny, nz = parse.(Int, split(readline(f)))
                origin     = Point3{T}(parse.(T, split(readline(f))))
                a_vec      = Vec3{T}(parse.(T, split(readline(f))))
                b_vec      = Vec3{T}(parse.(T, split(readline(f))))
                c_vec      = Vec3{T}(parse.(T, split(readline(f))))
                return [origin +
                        ia * a_vec +
                        ib * b_vec +
                        ic * c_vec for ia in range(0, 1, length=nx),
                                       ib in range(0, 1, length=ny),
                                       ic in range(0, 1, length=nz)]
            end
        end
    end
end
read_points_from_xsf(filename::String) = read_points_from_xsf(Float64, filename)

"""
read_values_from_xsf(filename::String, atom::Atom, T=Float64)

Returns an Array from reading a Wannier wavefunction file.
"""
function read_values_from_xsf(::Type{T}, filename::String) where {T <: AbstractFloat}
    open(filename) do f
        while !eof(f)
            line = readline(f)
            if line == "PRIMVEC"
                cell  = [Point3{T}.(parse.(T, split(readline(f)))) for i=1:3]
            end

            if line == " DATAGRID_3D_DENSITY" || occursin("DATAGRID_3D_UNKNOWN", line)
                nx, ny, nz = parse.(Int, split(readline(f)))
	            for i = 1:4
		            readline(f)
	            end
                out     = Array{T}(undef, nx, ny, nz)
                line    = readline(f)
				counter = 1
                while line != "END_DATAGRID_3D"
                    for t in parse.(T, split(line))
	                    out[counter] = t
	                    counter += 1
                    end
                    line = readline(f)
                end
                return out
            end
        end
    end
end
read_values_from_xsf(filename::String) = read_values_from_xsf(Float64, filename)

"""
write_xsf_file(filename::String, wfc::Wfc3D{T}) where T<:AbstractFloat


Writes the real part of the Wfc3D to a .xsf file that is readable by XCrysden or VESTA.
"""
function write_xsf_file(filename::String, wfc)
    open(filename,"w") do f
        origin = wfc[1,1,1].p
        write(f,["# Generated from PhD calculations\n", "", "BEGIN_BLOCK_DATAGRID_3D\n", "3D_FIELD\n",
        "BEGIN_DATAGRID_3D_UNKNOWN\n"])
        write(f,"$(size(wfc)[1])    $(size(wfc)[2])     $(size(wfc)[3])\n")
        write(f,"$(origin[1])   $(origin[2])   $(origin[3])\n")
        write(f,"$(wfc[end,1,1].p[1]-origin[1])   $(wfc[end,1,1].p[2]-origin[2])   $(wfc[end,1,1].p[3]-origin[3])\n")
        write(f,"$(wfc[1,end,1].p[1]-origin[1])   $(wfc[1,end,1].p[2]-origin[2])   $(wfc[1,end,1].p[3]-origin[3])\n")
        write(f,"$(wfc[1,1,end].p[1]-origin[1])   $(wfc[1,1,end].p[2]-origin[2])   $(wfc[1,1,end].p[3]-origin[3])\n")
        for wfp in wfc
            write(f,"$(real(wfp.w)) ")
        end
        write(f,"\n")
        write(f,["END_DATAGRID_3D\n", "END_BLOCK_DATAGRID_3D\n"])
    end
end

@doc raw"""
	readhami(filename::String,structure::AbstractStructure{T})

Returns a vector of TbBlocks with the hopping parameters of the Wannier Tight Binding Hamiltonian.
"""
function readhami(filename::String, structure::AbstractStructure{T, LT}) where  {T<:AbstractFloat,LT<:Length{T}}
    open(filename) do f
        out = TbBlock{T, Matrix{Complex{T}}, LT}[]
        degen = Int64[]
        linenr = 0
        readline(f)
        nwanfun = parse(Int64, readline(f))
        ndegen  = parse(Int64, readline(f))
        while length(degen) < ndegen
            push!(degen, parse.(Int, split(readline(f)))...)
        end
        while !eof(f)
            l = split(readline(f))
            linenr += 1
            rpt = div(linenr - 1, nwanfun^2) + 1
            R_cryst = Vec3(parse(Int, l[1]), parse(Int, l[2]), parse(Int, l[3]))
            if length(out) < rpt
                block = TbBlock(cell(structure)' * R_cryst, R_cryst, Matrix{Complex{T}}(I, nwanfun, nwanfun))
                push!(out, block)
            else
                block = out[rpt]
            end
            complex = Complex{T}(parse(T, l[6]), parse(T, l[7])) / degen[rpt]
            block.block[parse(Int, l[4]), parse(Int, l[5])] = complex
        end
        return out
    end
end

#super not optimized
@doc raw"""
	read_colin_hami(upfile::String, downfile::String, structure::AbstractStructure{T})

Returns an array of tuples that define the hopping parameters of the Wannier Tight Binding Hamiltonian.
"""
function read_colin_hami(upfile::String, downfile::String, structure::AbstractStructure{T}) where  T
	uphami   = readhami(upfile, structure)
	downhami = readhami(downfile, structure)
	dim = blocksize(uphami)
	CT = Complex{T}
	@assert dim == blocksize(downhami) "Specified files contain Hamiltonians with different dimensions of the Wannier basis."

	u1 = uphami[1]
	d1 = downhami[1]
	first = TbBlock(u1.R_cart, u1.R_cryst, ColinMatrix(block(u1), block(d1)))
	outhami  = [first]
	for (u, d) in zip(uphami[2:end], downhami[2:end])
		tmat = ColinMatrix(block(u), block(d))
		push!(outhami, TbBlock(u.R_cart, u.R_cryst, tmat))
	end
	return outhami
end

#TODO make this more robust
"""
    readhamis(job::DFJob)
"""
function readhami(job::DFJob)
	if !any(DFC.iscolincalc.(job.inputs))
		return readhami(job.local_dir * searchdir(job.local_dir, "hr.dat")[1], (job.structure,))
	else
		return read_colin_hami(joinpath.((job,), searchdir(job.local_dir, "hr.dat"))..., job.structure)
	end
end

"""
read_rmn_file(filename::String, structure::AbstractStructure{T})

Returns and array of tuples that define the dipoles between the Wannier functions in different unit cells.
"""
function read_rmn_file(filename::String, structure::AbstractStructure{T}) where T
    open(filename) do  f
        out = RmnBlock{T}[]
        readline(f)
        n_wanfun = parse(Int, readline(f))
        readline(f)
        while !eof(f)
            l= split(readline(f))
            R_cryst = Vec3(parse.(Int, l[1:3]))
            block = getfirst(x -> x.R_cryst == R_cryst, out)

            if block == nothing
                block = RmnBlock{T}(cell(structure)' * R_cryst, R_cryst, Matrix{Point3{T}}(I, n_wanfun, n_wanfun))
                push!(out, block)
            end
            dipole = Point3{T}(parse.(T, l[6:2:10]))
            block.block[parse.(Int, l[4:5])...] = dipole
        end
        return out
    end
end


#stuff that is not used currently
# """
# read_potential_file(filename::String, T=Float64)
#
# Reads a Quantum Espresso potential output file.
# """
# function read_potential_file(filename::String, T=Float64)
#     tmp_data=nothing
#     open(filename) do f
#         primCell = zeros(I, 3, 3)
#         while !eof(f)
#             line = readline(f)
#             if line == "PRIMVEC"
#                 for i=1:3
#                     primCell[i,:] = split(readline(f)) |> parse(T)
#                 end
#             end
#             if line == "DATAGRID_3D_UNKNOWN"
#                 nx, ny, nz = parse.(Int, split(readline(f)))
#                 for i = 1:4
#                     split(readline(f))
#                 end
#                 tmp_data=Array(T, nx, ny, nz)
#                 line = readline(f)
#                 k, k1, k2=1, 1, 1
#                 while line!= "END_DATAGRID_3D"
#                     tmp = Array{T}(map(x->(v = tryparse(T,x); isnull(v) ? 0.0 : get(v)),split(line)))
#                     for t in tmp
#                         tmp_data[k,k1,k2] = t
#                         if k<nx
#                             k+=1
#                         else
#                             k=1
#                             k1+=1
#                             if k1>ny
#                                 k1=1
#                                 k2+=1
#                                 if k2>nz
#                                     k2=1
#                                 end
#                             end
#                         end
#                     end
#                     line = readline(f)
#                 end
#                 return interpolate(tmp_data,BSpline(Cubic(Line())),OnGrid())
#             end
#         end
#     end
# end

#-------------------------Not currently used beyond here!------------------#
function write_dip_file(filename::String,points,cell,atoms,names,direction)
    open(filename,"w") do f
        origin = points[1,1,1][1]
        write(f,["# Generated from PhD calculations\n"])
        write(f,["CRYSTAL\n","PRIMVEC\n"])
        write(f,["$(cell[1][1])  $(cell[1][2]) $(cell[1][3])\n"])
        write(f,["$(cell[2][1])  $(cell[2][2]) $(cell[2][3])\n"])
        write(f,["$(cell[3][1])  $(cell[3][2]) $(cell[3][3])\n"])
        write(f,["CONVVEC\n"])
        write(f,["$(cell[1][1])  $(cell[1][2]) $(cell[1][3])\n"])
        write(f,["$(cell[2][1])  $(cell[2][2]) $(cell[2][3])\n"])
        write(f,["$(cell[3][1])  $(cell[3][2]) $(cell[3][3])\n"])
        write(f,["PRIMCOORD\n"])
        write(f,["  $(length(atoms)) 1\n"])
        for (atom,name) in zip(atoms,names)
            write(f,["$name  $(atom.center[1])  $(atom.center[2])  $(atom.center[3])\n"])
        end

        write(f,["", "BEGIN_BLOCK_DATAGRID_3D\n", "3D_FIELD\n",
        "BEGIN_DATAGRID_3D_UNKNOWN\n"])
        write(f,"$(size(points)[1])    $(size(points)[2])     $(size(points)[3])\n")
        write(f,"$(origin[1])   $(origin[2])   $(origin[3])\n")
        write(f,"$(points[end,1,1][1][1]-origin[1])   $(points[end,1,1][1][2]-origin[2])   $(points[end,1,1][1][3]-origin[3])\n")
        write(f,"$(points[1,end,1][1][1]-origin[1])   $(points[1,end,1][1][2]-origin[2])   $(points[1,end,1][1][3]-origin[3])\n")
        write(f,"$(points[1,1,end][1][1]-origin[1])   $(points[1,1,end][1][2]-origin[2])   $(points[1,1,end][1][3]-origin[3])\n")
        for point in points
            write(f,"$(point[2][direction]) ")
        end
        write(f,"\n")
        write(f,["END_DATAGRID_3D\n", "END_BLOCK_DATAGRID_3D\n"])
    end
end

function read_xsf_file_GPU(filename::String, T=Float64)
    open(filename) do f
        while !eof(f)
            line = readline(f)
            if line == " DATAGRID_3D_DENSITY"
                line0 = split(readline(f))
                line1 = split(readline(f))
                line2 = split(readline(f))
                line3 = split(readline(f))
                line4 = split(readline(f))
                nx = parse(Int,line0[1])
                ny = parse(Int,line0[2])
                nz = parse(Int,line0[3])
                out = Complex(T,nx,ny,nz)
                line = readline(f)
                k=1
                k1=1
                k2=1
                while line!= "END_DATAGRID_3D"
                    tmp = Array{Complex{T}}(map(x->(v = tryparse(T,x); isnull(v) ? Complex(0.0,0.0) : Complex{T}(get(v),0.0)),split(line)))
                    for t in tmp
                        out[k,k1,k2] = t
                        if k<nx
                            k+=1
                        else
                            k=1
                            k1+=1
                            if k1>ny
                                k1=1
                                k2+=1
                                if k2>nz
                                    k2=1
                                end
                            end
                        end
                    end
                    line = readline(f)
                end
                return out
            end
            if line == "BEGIN_DATAGRID_3D_UNKNOWN"
                line0 = split(readline(f))
                line1 = split(readline(f))
                line2 = split(readline(f))
                line3 = split(readline(f))
                line4 = split(readline(f))
                nx = parse(Int,line0[1])
                ny = parse(Int,line0[2])
                nz = parse(Int,line0[3])
                out = Array(Complex{T},nx,ny,nz)
                line = readline(f)
                k=1
                k1=1
                k2=1
                while line!= "END_DATAGRID_3D"
                    tmp = Array{Complex{T}}(map(x->(v = tryparse(T,x); isnull(v) ? Complex(0.0,0.0) : Complex{T}(get(v),0.0)),split(line)))
                    for t in tmp
                        out[k,k1,k2] = t
                        if k<nx
                            k+=1
                        else
                            k=1
                            k1+=1
                            if k1>ny
                                k1=1
                                k2+=1
                                if k2>nz
                                    k2=1
                                end
                            end
                        end
                    end
                    line = readline(f)
                end
                return out
            end
        end
    end
end

# function write_dipole_mesh(filename,mesh::Array{Tuple{Point3{T},Point3{T}},3},direction) where T
#     tmp_points = similar(mesh,WfPoint3{T})
#     for (ip,p) in enumerate(mesh)
#         tmp_points[ip] = WfcPoint3{T}(getfield(p[2],direction),p[1])
#     end
#     write_xsf_file(filename,Wfc3D(tmp_points,Point3{T}[],Atom()))
# end

function write_exchanges(filename::String, structure::Structure)
    open(filename, "w") do f
        exchanges = data(structure)[:exchanges]
        for (i, atom1) in enumerate(atoms(structure))
            for (i2, atom2) in enumerate(atoms(structure)[i + 1:end])
                J = exchange_between(atom1, atom2, exchanges)
                if J != 0
                    write(f, "$i:$(name(atom1)) -> $(i2+i):$(name(atom2)) $J\n")
                end
            end
        end
    end
end

function read_exchanges(filename::String, T=Float64)
    open(filename, "r") do f
        out = T[]
        indices = Tuple{Int,Int}[]
        max = 0
        while !eof(f)
            spl = split(readline(f))
            i, j = parse.(Int, spl[1:2])
            if j> max
                max = j
            end
            push!(indices, (i,j))
            exch = parse(T, spl[3])
            push!(out, exch)
        end
        real_out = zeros(T, (max, max))
        for (o, (i, j)) in zip(out, indices)
            real_out[i, j] = o
        end
        return real_out
    end
end

struct WannierParameters
    n_bands::Int
    n_excluded_bands::Int
    real_lattice::Mat3{Float64}
    recip_lattice::Mat3{Float64}
    n_kpoints::Int
    mp_grid::Vec3{Int}
    kpt_lattice::Vector{Vec3{Float64}}
    k_nearest_neighbors::Int
    n_wann::Int
    have_disentangled::Bool
    omega_invariant::Float64
    lwindow::Matrix{Bool}
    ndimwin::Vector{Int}
    U_matrix_opt::Array{Float64, 3}
    U_matrix::Array{Float64, 3}
    m_matrix::Array{Float64, 4}
    wannier_centers::Vector{Point3{Float64}}
    wannier_spreads::Vector{Float64}
end
function wan_read_chk(filename)
    f = FortranFile(filename)
    header = String(read(f, FString{33}))
    n_bands = Int(read(f, Int32))
    n_excluded_bands = Int(read(f, Int32))
    # exclude_bands_t = zeros(Int32, n_excluded_bands)
    read(f, (Int32, n_excluded_bands))
    # exclude_bands= convert.(Int, exclude_bands_t)
    read(f)
    real_lattice = Mat3(read(f, (Float64, 3, 3))...)
    recip_lattice = Mat3(read(f, (Float64, 3, 3))...)
    n_kpoints = read(f, Int32)
    mp_grid = Vec3(Int.(read(f, (Int32, 3)))...)
    kpt_lattice_t = read(f, (Float64, 3, n_kpoints))
    kpt_lattice = [Vec3(kpt_lattice_t[:, i]...) for i = 1:size(kpt_lattice_t)[2]]
    k_nearest_neighbors = read(f, Int32)

    n_wann = read(f, Int32)
    chkpt = strip(String(read(f, FString{20})))
    have_disentangled = read(f, Int32) == 1 ? true : false
    if have_disentangled
        omega_invariant = read(f, Float64)
        lwindow = map(x-> x==1 ? true : false, read(f, (Int32, n_bands, n_kpoints)))
        ndimwin = read(f, (Int32, n_kpoints))
        U_matrix_opt = read(f, (Float64, n_bands, n_wann, n_kpoints))
    else
        omega_invariant = 0.0
        lwindow = Matrix{Int}()
        ndimwin = Vector{Int}()
        U_matrix_opt= Array{Float64, 3}()
    end
    U_matrix = read(f, (Float64, n_wann, n_wann, n_kpoints))
    m_matrix = read(f, (Float64, n_wann, n_wann, k_nearest_neighbors, n_kpoints))
    wannier_centers_t = read(f, (Float64, 3, n_wann))
    wannier_centers = [Point3(wannier_centers_t[:, i]...) for i = 1:size(wannier_centers_t)[2]]
    wannier_spreads = read(f, (Float64, n_wann))
    return WannierParameters(
        n_bands,
        n_excluded_bands,
        real_lattice,
        recip_lattice,
        n_kpoints,
        mp_grid,
        kpt_lattice,
        k_nearest_neighbors,
        n_wann,
        have_disentangled,
        omega_invariant,
        lwindow,
        ndimwin,
        U_matrix_opt,
        U_matrix,
        m_matrix,
        wannier_centers,
        wannier_spreads
    )
end



