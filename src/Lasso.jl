module Lasso
using StatsBase
module Util
    # Extract fields from object into function locals
    # See https://github.com/JuliaLang/julia/issues/9755
    macro extractfields(from, fields...)
        esc(Expr(:block, [:($(fields[i]) = $(from).$(fields[i])) for i = 1:length(fields)]...))
    end
    export @extractfields
end

import Base.LinAlg.BlasReal
include("FusedLasso.jl")
include("TrendFiltering.jl")

using Reexport, StatsBase, .Util, MLBase
@reexport using GLM, Distributions, .FusedLassoMod, .TrendFiltering
using GLM.FPVector
export RegularizationPath, LassoPath, GammaLassoPath, NaiveCoordinateDescent,
       CovarianceCoordinateDescent, fit, fit!, coef, predict,
       minAICc, hasintercept, df, aicc, distfun, linkfun, cross_validate_path


## HELPERS FOR SPARSE COEFFICIENTS

immutable SparseCoefficients{T} <: AbstractVector{T}
    coef::Vector{T}              # Individual coefficient values
    coef2predictor::Vector{Int}  # Mapping from indices in coef to indices in original X
    predictor2coef::Vector{Int}  # Mapping from indices in original X to indices in coef

    SparseCoefficients(n::Int) = new(T[], Int[], zeros(Int, n))
end

function Base.A_mul_B!{T}(out::Vector, X::Matrix, coef::SparseCoefficients{T})
    fill!(out, zero(eltype(out)))
    @inbounds for icoef = 1:nnz(coef)
        ipred = coef.coef2predictor[icoef]
        c = coef.coef[icoef]
        @simd for i = 1:size(X, 1)
            out[i] += c*X[i, ipred]
        end
    end
    out
end

function Base.A_mul_B!{T}(out::Vector, X::SparseMatrixCSC, coef::SparseCoefficients{T})
    @extractfields X colptr rowval nzval
    fill!(out, zero(eltype(out)))
    @inbounds for icoef = 1:nnz(coef)
        ipred = coef.coef2predictor[icoef]
        c = coef.coef[icoef]
        @simd for i = colptr[ipred]:colptr[ipred+1]-1
            out[rowval[i]] += c*nzval[i]
        end
    end
    out
end

function Base.dot{T}(x::Vector{T}, coef::SparseCoefficients{T})
    v = 0.0
    @inbounds @simd for icoef = 1:nnz(coef)
        v += x[coef.coef2predictor[icoef]]*coef.coef[icoef]
    end
    v
end

Base.size(x::SparseCoefficients) = (length(x.predictor2coef),)
Base.nnz(x::SparseCoefficients) = length(x.coef)
Base.getindex{T}(x::SparseCoefficients{T}, ipred::Int) =
    x.predictor2coef[ipred] == 0 ? zero(T) : x.coef[x.predictor2coef[ipred]]

function Base.setindex!{T}(A::Matrix{T}, coef::SparseCoefficients, rg::UnitRange{Int}, i::Int)
    A[:, i] = zero(T)
    for icoef = 1:nnz(coef)
        A[rg[coef.coef2predictor[icoef]], i] = coef.coef[icoef]
    end
    A
end

function Base.copy!(x::SparseCoefficients, y::SparseCoefficients)
    length(x) == length(y) || throw(DimensionMismatch())
    n = length(y.coef)
    resize!(x.coef, n)
    resize!(x.coef2predictor, n)
    copy!(x.coef, y.coef)
    copy!(x.coef2predictor, y.coef2predictor)
    copy!(x.predictor2coef, y.predictor2coef)
    x
end

# Add a new coefficient to x, returning its index in x.coef
function addcoef!{T}(x::SparseCoefficients{T}, ipred::Int)
    push!(x.coef, zero(T))
    push!(x.coef2predictor, ipred)
    coefindex = nnz(x)
    x.predictor2coef[ipred] = coefindex
end

# Add newcoef to column i of coefs
function addcoefs!(coefs::SparseMatrixCSC, newcoef::SparseCoefficients, i::Int)
    n = nnz(coefs)
    nzval = coefs.nzval
    rowval = coefs.rowval
    resize!(nzval, n+nnz(newcoef))
    resize!(rowval, n+nnz(newcoef))
    @inbounds for ipred = 1:length(newcoef.predictor2coef)
        icoef = newcoef.predictor2coef[ipred]
        if icoef != 0
            cval = newcoef.coef[icoef]
            if cval != 0
                n += 1
                nzval[n] = cval
                rowval[n] = ipred
            end
        end
    end
    resize!(nzval, n)
    resize!(rowval, n)
    coefs.colptr[i+1:end] = n+1
end

## COEFFICIENT ITERATION IN SEQUENTIAL OR RANDOM ORDER
immutable RandomCoefficientIterator
    rng::MersenneTwister
    rg::Base.Random.RangeGeneratorInt{Int,UInt}
    coeforder::Vector{Int}
end
const RANDOMIZE_DEFAULT = true

RandomCoefficientIterator() =
    RandomCoefficientIterator(MersenneTwister(1337), Base.Random.RangeGenerator(1:2), Int[])
typealias CoefficientIterator Union{UnitRange{Int},RandomCoefficientIterator}

# Iterate over coefficients in random order
function Base.start(x::RandomCoefficientIterator)
    if !isempty(x.coeforder)
        @inbounds for i = length(x.coeforder):-1:2
            j = rand(x.rng, x.rg)
            x.coeforder[i], x.coeforder[j] = x.coeforder[j], x.coeforder[i]
        end
    end
    return 1
end
Base.next(x::RandomCoefficientIterator, i) = (x.coeforder[i], i += 1)
Base.done(x::RandomCoefficientIterator, i) = i > length(x.coeforder)

# Add an additional coefficient and return a new CoefficientIterator
function addcoef(x::RandomCoefficientIterator, icoef::Int)
    push!(x.coeforder, icoef)
    RandomCoefficientIterator(x.rng, Base.Random.RangeGenerator(1:length(x.coeforder)), x.coeforder)
end
addcoef(x::UnitRange{Int}, icoef::Int) = 1:length(x)+1

abstract RegularizationPath{S<:Union{LinearModel,GeneralizedLinearModel},T} <: RegressionModel
## LASSO PATH

type LassoPath{S<:Union{LinearModel,GeneralizedLinearModel},T} <: RegularizationPath{S,T}
    m::S
    nulldev::T                    # null deviance
    nullb0::T                     # intercept of null model, if one was fit
    λ::Vector{T}                  # shrinkage parameters
    autoλ::Bool                   # whether λ is automatically determined
    Xnorm::Vector{T}              # original squared norms of columns of X before standardization
    pct_dev::Vector{T}            # percent deviance explained by each model
    coefs::SparseMatrixCSC{T,Int} # model coefficients
    b0::Vector{T}                 # model intercepts
    niter::Int                    # number of coordinate descent iterations

    LassoPath(m, nulldev::T, nullb0::T, λ::Vector{T}, autoλ::Bool, Xnorm::Vector{T}) =
        new(m, nulldev, nullb0, λ, autoλ, Xnorm)
end

function Base.show(io::IO, path::RegularizationPath)
    prefix = isa(path.m, GeneralizedLinearModel) ? string(typeof(distfun(path)).name.name, " ") : ""
    println(io, "$(prefix)$(typeof(path).name.name) ($(size(path.coefs, 2)) solutions for $(size(path.coefs, 1)) predictors in $(path.niter) iterations):")

    if isdefined(path, :coefs)
        coefs = path.coefs
        ncoefs = zeros(Int, size(coefs, 2))
        for i = 1:size(coefs, 2)-1
            ncoefs[i] = coefs.colptr[i+1] - coefs.colptr[i]
        end
        ncoefs[end] = nnz(coefs) - coefs.colptr[size(coefs, 2)] + 1
        show(io, CoefTable(Union{Vector{Int},Vector{Float64}}[path.λ, path.pct_dev, ncoefs], ["λ", "pct_dev", "ncoefs"], []))
    else
        print(io, "    (not fit)")
    end
end

## MODEL CONSTRUCTION

# Controls early stopping criteria with automatic λ
const MIN_DEV_FRAC_DIFF = 1e-5
const MAX_DEV_FRAC = 0.999

# Compute automatic λ values based on X'y and λminratio
function computeλ(Xy, λminratio, α, nλ, ω::Union{Vector,Void})
    λmax = abs(Xy[1])
    if !isa(ω, Void)
        λmax /= ω[1]
    end
    for i = 2:length(Xy)
        x = abs(Xy[i])
        if !isa(ω, Void)
            x /= ω[i]
        end
        if x > λmax
            λmax = x
        end
    end
    λmax /= α
    logλmax = log(λmax)
    λ = exp.(linspace(logλmax, logλmax + log(λminratio), nλ))
end

# rescales A so that it sums to base
rescale(A, base) = A * (base / sum(A))

function build_model{T}(X::AbstractMatrix{T}, y::FPVector, d::Normal, l::IdentityLink,
                        lp::LinPred, λminratio::Real, λ::Union{Vector,Void},
                        wts::Union{FPVector,Void}, offset::Vector, α::Real, nλ::Int,
                        ω::Union{Vector, Void}, intercept::Bool, irls_tol::Real)
    # Special no-IRLS case
    mu = isempty(offset) ? y : y + offset
    nullb0 = intercept ? mean(mu, weights(wts)) : zero(T)
    nulldev = 0.0
    @simd for i = 1:length(mu)
        @inbounds nulldev += abs2(mu[i] - nullb0)*wts[i]
    end

    if λ == nothing
        # Find max λ
        if intercept
            muscratch = Array(T, length(mu))
            @simd for i = 1:length(mu)
                @inbounds muscratch[i] = (mu[i] - nullb0)*wts[i]
            end
        else
            muscratch = mu.*wts
        end
        Xy = X'muscratch
        λ = computeλ(Xy, λminratio, α, nλ, ω)
    else
        λ = convert(Vector{T}, λ)
    end

    # First y is just a placeholder here
    model = LinearModel(LmResp{typeof(y)}(mu, offset, wts, y), lp)
    (model, nulldev, nullb0, λ)
end

function build_model{T}(X::AbstractMatrix{T}, y::FPVector, d::UnivariateDistribution, l::Link,
                        lp::LinPred, λminratio::Real, λ::Union{Vector,Void},
                        wts::Union{FPVector,Void}, offset::Vector, α::Real, nλ::Int,
                        ω::Union{Vector, Void}, intercept::Bool, irls_tol::Real)
    # Fit to find null deviance
    # Maybe we should reuse this GlmResp object?
    nullmodel = fit(GeneralizedLinearModel, ones(T, length(y), ifelse(intercept, 1, 0)), y, d, l;
                    wts=wts, offset=offset, convTol=irls_tol)
    nulldev = deviance(nullmodel)

    if λ == nothing
        # Find max λ
        Xy = X'*broadcast!(*, nullmodel.rr.wrkresid, nullmodel.rr.wrkresid, nullmodel.rr.wrkwt)
        λ = computeλ(Xy, λminratio, α, nλ, ω)
        nullb0 = intercept ? coef(nullmodel)[1] : zero(T)
    else
        λ = convert(Vector{T}, λ)
        nullb0 = zero(T)
    end

    eta = GLM.initialeta!(d, l, similar(y), y, wts, offset)
    rr = GlmResp(y, d, l, eta, similar(eta), offset, wts)
    model = GeneralizedLinearModel(rr, lp, false)

    (model, nulldev, nullb0, λ)
end

defaultalgorithm(d::Normal, l::IdentityLink, n::Int, p::Int) = p > 5n ? NaiveCoordinateDescent : CovarianceCoordinateDescent
defaultalgorithm(d::UnivariateDistribution, l::Link, n::Int, p::Int) = NaiveCoordinateDescent

function StatsBase.fit{T<:AbstractFloat,V<:FPVector}(::Type{LassoPath},
                                                     X::AbstractMatrix{T}, y::V, d::UnivariateDistribution=Normal(),
                                                     l::Link=canonicallink(d);
                                                     wts::Union{FPVector,Void}=ones(T, length(y)),
                                                     offset::V=similar(y, 0),
                                                     α::Number=one(eltype(y)), nλ::Int=100,
                                                     λminratio::Number=ifelse(size(X, 1) < size(X, 2), 0.01, 1e-4),
                                                     λ::Union{Vector,Void}=nothing, standardize::Bool=true,
                                                     intercept::Bool=true,
                                                     algorithm::Type=defaultalgorithm(d, l, size(X, 1), size(X, 2)),
                                                     dofit::Bool=true,
                                                     irls_tol::Real=1e-7, randomize::Bool=RANDOMIZE_DEFAULT,
                                                     maxncoef::Int=min(size(X, 2), 2*size(X, 1)),
                                                     penalty_factor::Union{Vector,Void}=nothing,
                                                     fitargs...)
    size(X, 1) == size(y, 1) || DimensionMismatch("number of rows in X and y must match")
    n = length(y)
    length(wts) == n || error("length(wts) = $(length(wts)) should be 0 or $n")

    # Standardize predictors if requested
    if standardize
        Xnorm = vec(full(std(X, 1, corrected=false)))
        if any(x -> x == zero(T), Xnorm) 
            warn("""One of the predicators (columns of X) is a constant, so it can not be standardized. 
                  To include a constant predicator set standardize = false and intercept = false""") 
        end
        for i = 1:length(Xnorm)
            @inbounds Xnorm[i] = 1/Xnorm[i]
        end
        X = X .* Xnorm.'
    else
        Xnorm = T[]
    end

    # Lasso initialization
    α = convert(T, α)
    λminratio = convert(T, λminratio)
    coefitr = randomize ? RandomCoefficientIterator() : (1:0)

    # penalty_factor (ω) defaults to a vector of ones
    ω = penalty_factor
    if !isa(ω, Void)
        # following glmnet rescale penalty factors to sum to the number of coefficients
        ω = rescale(ω, size(X, 2))
    end

    cd = algorithm{T,intercept,typeof(X),typeof(coefitr),typeof(ω)}(X, α, maxncoef, 1e-7, coefitr, ω)

    # GLM response initialization
    autoλ = λ == nothing
    model, nulldev, nullb0, λ = build_model(X, y, d, l, cd, λminratio, λ, wts .* T(1/sum(wts)),
                                            Vector{T}(offset), α, nλ, ω, intercept, irls_tol)

    # Fit path
    path = LassoPath{typeof(model),T}(model, nulldev, nullb0, λ, autoλ, Xnorm)
    if dofit
        fit!(path; irls_tol=irls_tol, fitargs...)
    end
    path
end

StatsBase.nobs(path::RegularizationPath) = length(path.m.rr.y)


dispersion_parameter(path::RegularizationPath) = GLM.dispersion_parameter(distfun(path))

function StatsBase.loglikelihood(path::RegularizationPath)
    n = nobs(path)
    if typeof(path.m) <: LinearModel
        -0.5.*n.*log.(deviance(path))
    else
        -0.5.*n.*deviance(path)
    end
end

"""
    df(path::RegularizationPath)

Approximates the degrees-of-freedom in each segment of the path as the number of non zero coefficients
plus a dispersion parameter when appropriate.
Note that for GammaLassoPath this may be a crude approximation, as gamlr does this differently.
"""
function StatsBase.df(path::RegularizationPath)
    nλ = length(path.λ)
    βs = coef(path)
    dof = zeros(Int,nλ)
    for s=1:nλ
        dof[s] = sum(βs[:,s].!=0)
    end

    if dispersion_parameter(path)
        # add one for dispersion_parameter
        dof+=1
    end

    dof
end

function StatsBase.aicc(path::RegularizationPath;k=2)
    d = df(path)
    n = nobs(path)
    ic = -2loglikelihood(path) + k*d + k*d.*(d+1)./(n-d-1)
    ic[d.+1 .> n] = realmax(eltype(ic))
    ic
end

minAICc(path::RegularizationPath;k=2)=indmin(aicc(path;k=k))

hasintercept(path::RegularizationPath) = hasintercept(path.m.pp)

#Consistent with StatsBase.coef, if the model has an intercept it is included.
function StatsBase.coef(path::RegularizationPath; select=:all, nCVfolds=10)
    if !isdefined(path,:coefs)
        X = path.m.pp.X
        p = size(X,2)
        if hasintercept(path)
            p+=1
        end
        return zeros(eltype(X),p)
    end

    if select == :all
        if hasintercept(path)
            vcat(path.b0',path.coefs)
        else
            path.coefs
        end
    elseif select == :AICc
        if hasintercept(path)
            vec(vcat(path.b0[minAICc(path)],path.coefs[:,minAICc(path)]))
        else
            path.coefs[:,minAICc(path)]
        end
    elseif select == :CVmin || select == :CV1se
        gen = Kfold(length(path.m.rr.y),nCVfolds)
        segCV = cross_validate_path(path;gen=gen,select=select)
        if hasintercept(path)
            vec(vcat(path.b0[segCV],path.coefs[:,segCV]))
        else
            path.coefs[:,segCV]
        end
    else
        error("unknown selector $select")
    end
end

"link of underlying GLM"
GLM.linkfun{M<:LinearModel}(path::RegularizationPath{M}) = IdentityLink()
GLM.linkfun{V<:FPVector,D<:UnivariateDistribution,L<:Link,L2<:GLM.LinPred}(path::RegularizationPath{GeneralizedLinearModel{GlmResp{V,D,L},L2}}) = L()

## Prediction function for GLMs
function StatsBase.predict{T<:AbstractFloat}(path::RegularizationPath, newX::AbstractMatrix{T}; offset::FPVector=Array(T,0), select=:all)
    # add an interecept to newX if the model has one
    if hasintercept(path)
        newX = [ones(eltype(newX),size(newX,1),1) newX]
    end

    # calculate etas for each obs x segment
    eta = newX * coef(path;select=select)

    # get model
    mm = path.m

    # adjust for any offset
    if length(mm.rr.offset) > 0
        length(offset) == size(newX, 1) ||
            throw(ArgumentError("fit with offset, so `offset` kw arg must be an offset of length `size(newX, 1)`"))
        broadcast!(+, eta, eta, offset)
    else
        length(offset) > 0 && throw(ArgumentError("fit without offset, so value of `offset` kw arg does not make sense"))
    end

    if typeof(mm) <: LinearModel
        eta
    else
        # invert all etas to mus
        μ(η) = linkinv(linkfun(path), η)
        map(μ, eta)
    end
end

"distribution of underlying GLM"
distfun{M<:LinearModel}(path::RegularizationPath{M}) = Normal()
distfun(path::RegularizationPath) = path.m.rr.d

"deviance at each segment of the path for the fitted model and data"
StatsBase.deviance(path::RegularizationPath) = (1 .- path.pct_dev) .* path.nulldev # * nobs(path)

"""
deviance at each segement of the path for (potentially new) data X and y
select=:all or :AICc like in coef()
"""
function StatsBase.deviance{T<:AbstractFloat,V<:FPVector}(path::RegularizationPath, X::AbstractMatrix{T}, y::V;
                    offset::FPVector=Array(T,0), select=:all,
                    wts::FPVector=ones(T, length(y)))
    μ = predict(path, X; offset=offset, select=select)
    deviance(path, y, μ, wts)
end

"""
deviance at each segment of the path for (potentially new) y and predicted values μ
"""
function StatsBase.deviance{T<:AbstractFloat,V<:FPVector}(path::RegularizationPath, y::V, μ::AbstractArray{T},
                wts::FPVector=ones(T, length(y)))
    # get model specs from path
    d = distfun(path)

    # rescale weights
    wts = wts .* convert(T, 1/sum(wts))

    # closure for deviance of a single observation
    dev(ys,μs,ws) = ws * devresid(d, ys, μs)

    # deviances of all obs x segment
    devresidv = broadcast(dev,y,μ,wts)

    # deviance is just their sum
    if size(μ,2) > 1
        vec(sum(devresidv,1))
    else
        sum(devresidv)
    end
end

include("coordinate_descent.jl")
include("gammalasso.jl")
include("cross_validation.jl")

end
