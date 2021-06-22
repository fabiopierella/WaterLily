@inline ∂(a,I::CartesianIndex{d},f::AbstractArray{T,d}) where {T,d} = @inbounds f[I]-f[I-δ(a,I)]
@inline ∂(a,I::CartesianIndex{m},u::AbstractArray{T,n}) where {T,n,m} = @inbounds u[I+δ(a,I),a]-u[I,a]
@inline ϕ(a,I,f) = @inbounds (f[I]+f[I-δ(a,I)])*0.5
@fastmath quick(u,c,d) = median((5c+2d-u)/6,c,median(10c-9u,c,d))
@fastmath vanLeer(u,c,d) = (c≤min(u,d) || c≥max(u,d)) ? c : c+(d-c)*(c-u)/(d-u)
@inline ϕu(a,I,f,u,λ=quick) = @inbounds u>0 ? u*λ(f[I-2δ(a,I)],f[I-δ(a,I)],f[I]) : u*λ(f[I+δ(a,I)],f[I],f[I-δ(a,I)])
@fastmath @inline div(I::CartesianIndex{m},u) where {m} = sum(∂(i,I,u) for i ∈ 1:m)

@fastmath function tracer_transport!(r,f,u;Pe=0.1)
    N,n = size_u(u)
    for j ∈ 1:n
        @simd for I ∈ slice(N,2,j,2)
            Φ = ϕ(j,I,f)*u[I,j]-Pe*∂(j,I,f)
            @inbounds r[I] += Φ
        end
        @simd for I ∈ inside_u(N,j)
            Φ = ϕu(j,I,f,u[I,j])-Pe*∂(j,I,f)
            @inbounds r[I] += Φ
            @inbounds r[I-δ(j,I)] -= Φ
        end
        @simd for I ∈ slice(N,N[j],j,2)
            Φ = ϕ(j,I,f)*u[I,j]-Pe*∂(j,I,f)
            @inbounds r[I-δ(j,I)] -= Φ
        end
    end
end

@fastmath function conv_diff!(r,u;ν=0.1)
    r .= 0.
    N,n = size_u(u)
    for i ∈ 1:n, j ∈ 1:n
        @simd for I ∈ slice(N,2,j,2)
            Φ = ϕ(j,CI(I,i),u)*ϕ(i,CI(I,j),u)-ν*∂(j,CI(I,i),u)
            @inbounds r[I,i] += Φ
        end
        @simd for I ∈ inside_u(N,j)
            Φ = ϕu(j,CI(I,i),u,ϕ(i,CI(I,j),u))-ν*∂(j,CI(I,i),u)
            @inbounds r[I,i] += Φ
            @inbounds r[I-δ(j,I),i] -= Φ
        end
        @simd for I ∈ slice(N,N[j],j,2)
            Φ = ϕ(j,CI(I,i),u)*ϕ(i,CI(I,j),u)-ν*∂(j,CI(I,i),u)
            @inbounds r[I-δ(j,I),i] -= Φ
        end
    end
end

struct Flow{N,M,P,T}
    # Fluid fields
    u :: Array{T,M} # velocity vector
    u⁰:: Array{T,M} # previous velocity
    f :: Array{T,M} # force vector
    p :: Array{T,N} # pressure scalar
    σ :: Array{T,N} # divergence scalar
    # BDIM fields
    V :: Array{T,M} # body velocity vector
    σᵥ:: Array{T,N} # body velocity divergence
    μ₀:: Array{T,M} # zeroth-moment on faces
    μ₁:: Array{T,P} # first-moment vector on faces
    # Non-fields
    U :: Vector{T}  # domain boundary values
    Δt:: Vector{T}  # time step
    ν :: T          # kinematic viscosity
    function Flow(N::Tuple,U::Vector;Δt=0.25,ν=0.,uλ::Function=(i,x)->0.,T=Float64)
        d = length(N); Nd = (N...,d)
        @assert length(U)==d
        u = Array{T}(undef,Nd...); apply!(uλ,u); BC!(u,U)
        u⁰ = copy(u)
        f,p,σ = zeros(T,Nd),zeros(T,N),zeros(T,N)
        V,σᵥ = zeros(T,Nd),zeros(T,N)
        μ₀ = ones(T,Nd); BC!(μ₀,zeros(T,d))
        μ₁ = zeros(T,N...,d,d)
        new{d,d+1,d+2,T}(u,u⁰,f,p,σ,V,σᵥ,μ₀,μ₁,U,[Δt],ν)
    end
end

@fastmath function BDIM!(a::Flow{n}) where n
    @. a.f = a.u⁰+a.Δt[end]*a.f-a.V
    for j ∈ 1:n, i ∈ 1:n; @simd for I ∈ inside(a.p)
        @inbounds a.u[I,i] += μddn(j,CI(I,i),a.μ₁,a.f)
    end;end
    @. a.u += a.V+a.μ₀*a.f
end
@inline μddn(j,I::CartesianIndex,μ,f) = @inbounds 0.5μ[I,j]*(f[I+δ(j,I)]-f[I-δ(j,I)])

@fastmath function project!(a::Flow{n},b::AbstractPoisson{n},w=1) where n
    @inside a.σ[I] = (div(I,a.u)+w*a.σᵥ[I])/a.Δt[end]
    solver!(a.p,b,a.σ)
    for i ∈ 1:n; @simd for I ∈ inside(a.σ)
        @inbounds  a.u[I,i] -= a.Δt[end]*a.μ₀[I,i]*∂(i,I,a.p)
    end;end
end

@fastmath function mom_step!(a::Flow,b::AbstractPoisson)
    a.u⁰ .= a.u; a.u .= 0
    # predictor u → u'
    conv_diff!(a.f,a.u⁰,ν=a.ν)
    BDIM!(a); BC!(a.u,a.U)
    project!(a,b); BC!(a.u,a.U)
    # corrector u → u¹
    conv_diff!(a.f,a.u,ν=a.ν)
    BDIM!(a); BC!(a.u,a.U,2)
    project!(a,b,2); a.u ./= 2; BC!(a.u,a.U)
    push!(a.Δt,CFL(a))
end

function CFL(a::Flow{n}) where n
    mx = mapreduce(I->fout(I,a.u),max,inside(a.p))
    min(10.,inv(mx+5a.ν))
end
@fastmath @inline fout(I::CartesianIndex{d},u) where {d} =
    sum(@inbounds(max(0.,u[I+δ(a,I),a])+max(0.,-u[I,a])) for a ∈ 1:d)
