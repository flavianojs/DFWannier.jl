using DFControl: form_directory,search_dir
import Base: norm, getindex, zero, show, -, +, ==, !=, *, /
# Cleanup Do we really need <:abstractfloat, check this!
"Point of a wavefunction in 3D, holds the complex value of the wavefunction and the cartesian coordinate."
struct WfcPoint3D{T<:AbstractFloat}
  w::Complex{T}
  p::Point3D{T}
end
+(a::WfcPoint3D,b::Point3D) = WfcPoint3D(a.w,a.p+b)
+(a::WfcPoint3D,b::WfcPoint3D) = a.p == b.p ? WfcPoint3D(a.w+b.w,a.p) : error("Can only sum two wavepoints at the same point in space!")
-(a::WfcPoint3D,b::Point3D) = WfcPoint3D(a.w,a.p-b)
+(a::WfcPoint3D{T},b::Complex{T}) where T = WfcPoint3D(a.w+b,a.p)
*(a::WfcPoint3D,b::AbstractFloat) = WfcPoint3D(a.w*b,a.p)
*(a::WfcPoint3D{T},b::Complex{T}) where T = WfcPoint3D(a.w*b,a.p)
*(b::AbstractFloat,a::WfcPoint3D) = WfcPoint3D(a.w*b,a.p)
*(b::Complex{T},a::WfcPoint3D{T}) where T = WfcPoint3D(a.w*b,a.p)
/(a::WfcPoint3D{T},b::Complex{T}) where T = WfcPoint3D(a.w/b,a.p)
show(io::IO,x::WfcPoint3D)=print(io,"w = $(x.w), x = $(x.p.x), y = $(x.p.y), z = $(x.p.z)")
zero(::Type{WfcPoint3D{T}}) where T<:AbstractFloat = WfcPoint3D(zero(Complex{T}),Point3D(zero(T)))

"Atom in 3D space, has a center in cartesian coordinates and a parameter for the spin-orbit coupling strength."
struct PhysAtom{T<:AbstractFloat}
  center::Point3D{T}
  l_soc::T
end
PhysAtom(x,y,z,l_soc)                                  = PhysAtom(Point3D(x,y,z),l_soc)
PhysAtom(::Type{T},x,y,z,l_soc) where T<:AbstractFloat = PhysAtom(T(x),T(y),T(z),T(l_soc))
PhysAtom(::Type{T}) where T<:AbstractFloat             = PhysAtom(Point3D(T,0.0),T(0.0))

"Wavefunction in 3D, holds an array of WfcPoint3D, the superlattice unit cell and the atom around which it lives."
mutable struct Wfc3D{T<:AbstractFloat}
  points::Array{WfcPoint3D{T},3}
  cell::Array{Point3D{T},1}
  atom::PhysAtom{T}
end
/(a::Wfc3D{T},b::Complex{T}) where T = Wfc3D(a.points./b,a.cell,a.atom)
+(a::Wfc3D,b::Wfc3D) = Wfc3D(a.points+b.points,a.cell,a.atom)
*(a::Wfc3D,b::AbstractFloat) = Wfc3D(a.points*b,a.cell,a.atom)
*(a::Wfc3D,b::Complex{AbstractFloat}) = Wfc3D(a.points*b,a.cell,a.atom)
*(b::AbstractFloat,a::Wfc3D) = Wfc3D(a.points*b,a.cell,a.atom)
*(b::Complex{T},a::Wfc3D{T}) where T = Wfc3D(a.points*b,a.cell,a.atom)

function norm(a::Wfc3D{T}) where T
  n = zero(T) 
  for point in a.points
    n += norm(point.w)^2
  end
  return sqrt(n)
end

function Base.normalize(wfc::Wfc3D{T}) where T
  n1 = zero(Complex{T})
  for point in wfc.points
    n1 += norm(point.w)^2
  end
  return wfc/sqrt(n1)
end

function getindex(x::Wfc3D,i1::Int,i2::Int,i3::Int)
  return x.points[i1,i2,i3]
end
function getindex(x::Wfc3D,i::CartesianIndex{3})
  return x.points[i[1],i[2],i[3]]
end

function Base.size(x::Wfc3D)
  return size(x.points)
end
function Base.size(x::Wfc3D,i::Int)
  return size(x.points,i)
end
show(io::IO,x::Wfc3D)=print(io,"Wavefunction Mesh of size($(size(x.points)),\n Physatom = $(x.atom)")

"Holds all the calculated values from a wannier model."
mutable struct WannierBand{T<:AbstractFloat} <: Band
  eigvals::Array{T,1}
  eigvec::Array{Array{Complex{T},1},1}
  cms::Array{Point3D{T},1}
  # epots::Array{T,1}
  angmoms::Array{Array{Point3D{T},1},1}
  spins::Array{Array{Point3D{T},1},1}
  k_points::Array{Array{T,1},1}
end

"Start of any Wannier calculation. Gets constructed by reading the Wannier Hamiltonian and wavefunctions, and gets used in Wannier calculations."
mutable struct WannierModel{T<:AbstractFloat}
  hami_raw::Array{Tuple{Int,Int,Int,Int,Int,Complex{T}},1}
  dip_raw::Array{Tuple{Int,Int,Int,Int,Int,Point3D{T}},1}
  wfcs::Array{Wfc3D{T},1}
  k_points::Array{Array{T,1},1}
  bands::Array{WannierBand{T},1}
  atoms::Array{PhysAtom{T},1}
  function WannierModel{T}(dir::String, k_points, atoms::Array{<:PhysAtom}) where T<:AbstractFloat
    dir = form_directory(dir)
    wfc_files = search_dir(dir,".xsf")
    hami_file = search_dir(dir,"_hr.dat")[1]
    dip_file = search_dir(dir,"_r.dat")[1]
    wfcs = Array{Wfc3D{T},1}(length(wfc_files))
    Threads.@threads for i=1:length(wfcs)
      wfcs[i] = read_xsf_file(dir*wfc_files[i],atoms[i],T)
    end
    hami_raw = read_hami_file(dir*hami_file,T)
    dip_raw = read_dipole_file(dir*dip_file,T)
    return new(hami_raw,dip_raw,wfcs,k_points,WannierBand{T}[],atoms)
  end
end
function WannierModel{T}(dir::String, k_point_file::String, atoms::Array{<:PhysAtom}) where T<:AbstractFloat
  k_points = read_ks_from_qe_bands_file(k_point_file,T)[2]
  return WannierModel{T}(dir,k_points,atoms)
end
