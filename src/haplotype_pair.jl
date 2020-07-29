"""
    haplochunk!(redundant_haplotypes, compressed_Hunique, X, ...)

Wrapper function that computes the best haplotype pair `(hᵢ, hⱼ)` for each
genotype vector in a given chunk.

# There are 5 timers (some may be 0):
t1 = screening for top haplotypes
t2 = BLAS3 mul! to get M and N
t3 = haplopair search
t4 = rescreen time
t5 = finding redundant happairs
"""
function haplochunk!(
    redundant_haplotypes::AbstractVector,
    compressed_Hunique::CompressedHaplotypes,
    X::AbstractMatrix,
    X_pos::AbstractVector,
    dynamic_programming::Bool,
    lasso::Union{Nothing, Int},
    tf::Union{Nothing, Int}, # thinning factor
    scale_allelefreq::Bool,
    max_haplotypes::Int,
    rescreen::Bool,
    winrange::UnitRange,
    total_window::Int,
    pmeter::Progress,
    timers::AbstractVector
    )
    people = size(X, 2)
    ref_snps = length(compressed_Hunique.pos)
    width = compressed_Hunique.width
    windows = length(winrange)
    threads = Threads.nthreads()
    tothaps = nhaplotypes(compressed_Hunique)
    avghaps = avg_haplotypes_per_window(compressed_Hunique)
    inv_sqrt_allele_var = nothing

    # return arrays
    haplotype1 = [zeros(Int32, windows) for i in 1:people]
    haplotype2 = [zeros(Int32, windows) for i in 1:people]

    # working arrays
    happair1 = [ones(Int32, people)           for _ in 1:threads]
    happair2 = [ones(Int32, people)           for _ in 1:threads]
    hapscore = [zeros(Float32, size(X, 2))    for _ in 1:threads]
    Xwork    = [zeros(Float32, width, people) for _ in 1:threads]
    if !isnothing(tf)
        maxindx = [zeros(Int, tf)       for _ in 1:threads]
        maxgrad = [zeros(Float32, tf)   for _ in 1:threads]
        Hk = [zeros(Float32, width, tf) for _ in 1:threads]
        Xi = [zeros(Float32, width)     for _ in 1:threads]
        M  = [zeros(Float32, tf, tf)    for _ in 1:threads]
        N  = [zeros(Float32, tf)        for _ in 1:threads]
    end
    if !isnothing(lasso)
        maxindx = [zeros(Int,     lasso) for _ in 1:threads]
        maxgrad = [zeros(Float32, lasso) for _ in 1:threads]
    end
    if !dynamic_programming
        redunhaps_bitvec1 = [falses(tothaps) for _ in 1:threads]
        redunhaps_bitvec2 = [falses(tothaps) for _ in 1:threads]
    end

    ThreadPools.@qthreads for absolute_w in winrange
        Hw_aligned = compressed_Hunique.CW_typed[absolute_w].uniqueH
        Xw_idx_start = (absolute_w - 1) * width + 1
        Xw_idx_end = (absolute_w == total_window ? length(X_pos) :
            absolute_w * width)
        Xw_aligned = view(X, Xw_idx_start:Xw_idx_end, :)
        d  = size(Hw_aligned, 2)
        id = Threads.threadid()

        # weight snp by inverse allele variance if requested
        if scale_allelefreq
            Hw_range = compressed_Hunique.start[absolute_w]:(absolute_w ==
                total_window ? ref_snps :
                               compressed_Hunique.start[absolute_w + 1] - 1)
            Hw_snp_pos = indexin(X_pos[Xw_idx_start:Xw_idx_end],
                compressed_Hunique.pos[Hw_range])
            inv_sqrt_allele_var = compressed_Hunique.altfreq[Hw_snp_pos]
            map!(x -> x < 0.15 ? 1.98 : 1 / sqrt(2*x*(1-x)),
                inv_sqrt_allele_var, inv_sqrt_allele_var) # set min pᵢ = 0.15
        end

        # compute top haplotype pairs for each sample in current window
        if !isnothing(lasso) && d > max_haplotypes
            # find hᵢ via stepwise regression, then find hⱼ via global search
            t1, t2, t3, t4 = haplopair_lasso!(Xw_aligned, Hw_aligned, r=lasso,
                inv_sqrt_allele_var=inv_sqrt_allele_var, happair1=happair1[id],
                happair2=happair2[id], hapscore=hapscore[id],
                maxindx=maxindx[id], maxgrad=maxgrad[id], Xwork=Xwork[id])
        elseif !isnothing(tf) && d > max_haplotypes
            # haplotype thinning: search all (hᵢ, hⱼ) pairs where hᵢ ≈ x ≈ hⱼ
            t1, t2, t3, t4 = haplopair_thin_BLAS2!(Xw_aligned, Hw_aligned,
                allele_freq=inv_sqrt_allele_var, keep=tf,
                happair1=happair1[id], happair2=happair2[id],
                hapscore=hapscore[id], maxindx=maxindx[id], maxgrad=maxgrad[id],
                Xi=Xi[id], N=N[id], Hk=Hk[id], M=M[id], Xwork=Xwork[id])
        elseif rescreen
            # global search + searching ||x - hᵢ - hⱼ|| on observed entries
            t1, t2, t3, t4 = haplopair_screen!(Xw_aligned, Hw_aligned,
                happair1=happair1[id], happair2=happair2[id],
                hapscore=hapscore[id], Xwork=Xwork[id])
        else
            # global search
            t1, t2, t3, t4 = haplopair!(Xw_aligned, Hw_aligned,
                inv_sqrt_allele_var=inv_sqrt_allele_var, happair1=happair1[id],
                happair2=happair2[id], hapscore=hapscore[id], Xwork=Xwork[id])
        end

        # convert happairs (which index off unique haplotypes) to indices of
        # full haplotype pool, and find all matching happairs
        t5 = @elapsed begin
            # w = something(findfirst(x -> x == absolute_w, winrange)) # window index of current chunk
            # compute_redundant_haplotypes!(redundant_haplotypes, compressed_Hunique,
            #     happair1[id], happair2[id], w, absolute_w, redunhaps_bitvec1[id],
            #     redunhaps_bitvec2[id])

            # save_unique_only!(redundant_haplotypes, compressed_Hunique,
            #     happair1[id], happair2[id], w, absolute_w, redunhaps_bitvec1[id],
            #     redunhaps_bitvec2[id])

            for i in 1:people
                haplotype1[i][absolute_w] = unique_idx_to_complete_idx(
                    happair1[id][i], absolute_w, compressed_Hunique)
                haplotype2[i][absolute_w] = unique_idx_to_complete_idx(
                    happair2[id][i], absolute_w, compressed_Hunique)
            end
        end

        # record timings and haplotypes
        timers[id][1] += t1
        timers[id][2] += t2
        timers[id][3] += t3
        timers[id][4] += t4
        timers[id][5] += t5

        # update progress
        next!(pmeter)
    end

    return haplotype1, haplotype2
end

"""
Records optimal-redundant haplotypes for each window.

Warning: This function is called in a multithreaded loop. If you modify this function
you must check whether imputation accuracy is affected (when run with >1 threads).

# Arguments:
- `window_idx`: window in current chunk
- `window_overall`: window index in terms of every windows
"""
function compute_redundant_haplotypes!(
    redundant_haplotypes::Vector{OptimalHaplotypeSet},
    Hunique::CompressedHaplotypes,
    happair1::AbstractVector,
    happair2::AbstractVector,
    window_idx::Int,
    window_overall::Int,
    storage1 = falses(nhaplotypes(Hunique)),
    storage2 = falses(nhaplotypes(Hunique))
    )

    people = length(redundant_haplotypes)

    @inbounds for k in 1:people
        # convert happairs from unique idx to complete idx
        Hi_idx = unique_idx_to_complete_idx(happair1[k], window_overall, Hunique)
        Hj_idx = unique_idx_to_complete_idx(happair2[k], window_overall, Hunique)

        # strand1
        storage1 .= false
        if haskey(Hunique.CW_typed[window_overall].hapmap, Hi_idx)
            h1_set = Hunique.CW_typed[window_overall].hapmap[Hi_idx]
            for i in h1_set
                storage1[i] = true
            end
        else
            storage1[Hi_idx] = true # Hi_idx is singleton (i.e. unique)
        end

        # strand2
        storage2 .= false
        if haskey(Hunique.CW_typed[window_overall].hapmap, Hj_idx)
            h2_set = Hunique.CW_typed[window_overall].hapmap[Hj_idx]
            for i in h2_set
                storage2[i] = true
            end
        else
            storage2[Hj_idx] = true # Hj_idx is singleton (i.e. unique)
        end

        # redundant_haplotypes[k].strand1[window_idx] = copy(storage1)
        # redundant_haplotypes[k].strand2[window_idx] = copy(storage2)
        if isassigned(redundant_haplotypes[k].strand1, window_idx)
            redundant_haplotypes[k].strand1[window_idx] .= storage1
            redundant_haplotypes[k].strand2[window_idx] .= storage2
        else
            redundant_haplotypes[k].strand1[window_idx] = copy(storage1)
            redundant_haplotypes[k].strand2[window_idx] = copy(storage2)
        end
    end

    return nothing
end

function save_unique_only!(
    redundant_haplotypes::Vector{OptimalHaplotypeSet},
    Hunique::CompressedHaplotypes,
    happair1::AbstractVector,
    happair2::AbstractVector,
    window_idx::Int,
    window_overall::Int,
    storage1 = falses(nhaplotypes(Hunique)),
    storage2 = falses(nhaplotypes(Hunique))
    )

    people = length(redundant_haplotypes)

    @inbounds for k in 1:people
        # convert happairs from unique idx to complete idx
        Hi_idx = unique_idx_to_complete_idx(happair1[k], window_overall, Hunique)
        Hj_idx = unique_idx_to_complete_idx(happair2[k], window_overall, Hunique)

        # strand1: save unique index
        storage1 .= false
        storage1[Hi_idx] = true # Hi_idx is singleton (i.e. unique)

        # strand2: save unique index
        storage2 .= false
        storage2[Hj_idx] = true # Hj_idx is singleton (i.e. unique)

        # redundant_haplotypes[k].strand1[window_idx] = copy(storage1)
        # redundant_haplotypes[k].strand2[window_idx] = copy(storage2)
        if isassigned(redundant_haplotypes[k].strand1, window_idx)
            redundant_haplotypes[k].strand1[window_idx] .= storage1
            redundant_haplotypes[k].strand2[window_idx] .= storage2
        else
            redundant_haplotypes[k].strand1[window_idx] = copy(storage1)
            redundant_haplotypes[k].strand2[window_idx] = copy(storage2)
        end
    end

    return nothing
end

"""
For person `i`, find redundant haplotypes matching each haplotype index in
redundant_haplotypes[i].strand1 and redundant_haplotypes[i].strand2 (which
should record complete index).
"""
function find_redundant_haplotypes!(
    redundant_haplotypes::Vector{OptimalHaplotypeSet},
    Hunique::CompressedHaplotypes,
    winrange::UnitRange,
    storage1 = falses(nhaplotypes(Hunique)),
    storage2 = falses(nhaplotypes(Hunique))
    )

    people = length(redundant_haplotypes)

    @inbounds for k in 1:people, w in winrange
        # get complete index
        Hi_idx = something(findfirst(redundant_haplotypes[k].strand1[w]))
        Hj_idx = something(findfirst(redundant_haplotypes[k].strand2[w]))

        # strand1
        storage1 .= false
        if haskey(Hunique.CW_typed[w].hapmap, Hi_idx)
            h1_set = Hunique.CW_typed[w].hapmap[Hi_idx]
            for i in h1_set
                storage1[i] = true
            end
        else
            storage1[Hi_idx] = true # Hi_idx is singleton (i.e. unique)
        end

        # strand2
        storage2 .= false
        if haskey(Hunique.CW_typed[w].hapmap, Hj_idx)
            h2_set = Hunique.CW_typed[w].hapmap[Hj_idx]
            for i in h2_set
                storage2[i] = true
            end
        else
            storage2[Hj_idx] = true # Hj_idx is singleton (i.e. unique)
        end

        # redundant_haplotypes[k].strand1[window_idx] = copy(storage1)
        # redundant_haplotypes[k].strand2[window_idx] = copy(storage2)
        if isassigned(redundant_haplotypes[k].strand1, w)
            redundant_haplotypes[k].strand1[w] .= storage1
            redundant_haplotypes[k].strand2[w] .= storage2
        else
            redundant_haplotypes[k].strand1[w] = copy(storage1)
            redundant_haplotypes[k].strand2[w] = copy(storage2)
        end
    end

    return nothing
end

function screen_flanking_windows!(
    redundant_haplotypes::Vector{OptimalHaplotypeSet},
    compressed_Hunique::CompressedHaplotypes,
    X::AbstractMatrix,
    winrange::UnitRange,
    total_window::Int,
    )

    people = length(redundant_haplotypes)
    haplotypes = nhaplotypes(compressed_Hunique)
    width = compressed_Hunique.width
    windows = length(winrange)

    for absolute_w in winrange
        w = something(findfirst(x -> x == absolute_w, winrange))
        Hw_aligned = compressed_Hunique.CW_typed[absolute_w].uniqueH
        Xw_idx_start = (absolute_w - 1) * width + 1
        Xw_idx_end = (absolute_w == total_window ? size(X, 1) : absolute_w * width)
        Xw_aligned = view(X, Xw_idx_start:Xw_idx_end, :)

        for i in 1:people
            # calculate observed error for current pair
            h1_curr_complete = something(findfirst(redundant_haplotypes[i].strand1[w])) # complete index
            h2_curr_complete = something(findfirst(redundant_haplotypes[i].strand2[w])) # complete index
            h1_curr = complete_idx_to_unique_typed_idx(h1_curr_complete, absolute_w, compressed_Hunique) # unique index
            h2_curr = complete_idx_to_unique_typed_idx(h2_curr_complete, absolute_w, compressed_Hunique) # unique index
            curr_err = observed_error(Xw_aligned, i, Hw_aligned, h1_curr, h2_curr) # calculate current erro

            # consider previous pair
            if w != 1
                h1_prev_complete = something(findfirst(redundant_haplotypes[i].strand1[w - 1]))
                h2_prev_complete = something(findfirst(redundant_haplotypes[i].strand2[w - 1]))
                h1_prev = complete_idx_to_unique_typed_idx(h1_prev_complete, absolute_w, compressed_Hunique) # unique index
                h2_prev = complete_idx_to_unique_typed_idx(h2_prev_complete, absolute_w, compressed_Hunique) # unique index
                prev_err = observed_error(Xw_aligned, i, Hw_aligned, h1_prev, h2_prev)
                if prev_err < curr_err
                    h1_curr, h2_curr, curr_err = h1_prev, h2_prev, prev_err
                end
            end

            # consider next pair
            if w != windows
                h1_next_complete = something(findfirst(redundant_haplotypes[i].strand1[w + 1]))
                h2_next_complete = something(findfirst(redundant_haplotypes[i].strand2[w + 1]))
                h1_next = complete_idx_to_unique_typed_idx(h1_next_complete, absolute_w, compressed_Hunique) # unique index
                h2_next = complete_idx_to_unique_typed_idx(h2_next_complete, absolute_w, compressed_Hunique) # unique index
                next_err = observed_error(Xw_aligned, i, Hw_aligned, h1_next, h2_next)
                if next_err < curr_err
                    h1_curr, h2_curr, curr_err = h1_next, h2_next, next_err
                end
            end

            # convert from unique idx to complete idx
            H1_idx = unique_idx_to_complete_idx(h1_curr, w, compressed_Hunique)
            H2_idx = unique_idx_to_complete_idx(h2_curr, w, compressed_Hunique)
            redundant_haplotypes[i].strand1[w][h1_curr_complete] = false # reset
            redundant_haplotypes[i].strand2[w][h2_curr_complete] = false # reset
            redundant_haplotypes[i].strand1[w][H1_idx] = true # save best
            redundant_haplotypes[i].strand2[w][H2_idx] = true # save best
        end
    end

    return nothing
end

# uses dynamic programming. Only the first 1000 haplotype pairs will be saved.
# function compute_redundant_haplotypes!(
#     redundant_haplotypes::Vector{Vector{Vector{T}}},
#     Hunique::CompressedHaplotypes,
#     happair1::AbstractVector,
#     happair2::AbstractVector,
#     window_idx::Int,
#     window_overall::Int,
#     storage1 = falses(nhaplotypes(Hunique)),
#     storage2 = falses(nhaplotypes(Hunique))
#     ) where T <: Tuple{Int32, Int32}

#     people = length(redundant_haplotypes)

#     @inbounds for k in 1:people
#         # convert happairs from unique idx to complete idx
#         Hi_idx = unique_idx_to_complete_idx(happair1[k], window_overall, Hunique)
#         Hj_idx = unique_idx_to_complete_idx(happair2[k], window_overall, Hunique)

#         # find haplotypes that match Hi_idx and Hj_idx on typed snps
#         h1_set = get(Hunique.CW_typed[window_overall].hapmap, Hi_idx, Hi_idx)
#         h2_set = get(Hunique.CW_typed[window_overall].hapmap, Hj_idx, Hj_idx)

#         # save first 1000 haplotype pairs
#         for h1 in h1_set, h2 in h2_set
#             if length(redundant_haplotypes[k][window_idx]) < 1000
#                 push!(redundant_haplotypes[k][window_idx], (h1, h2))
#             else
#                 break
#             end
#         end
#     end

#     return nothing
# end

"""
    haplopair(X, H)

Calculate the best pair of haplotypes in `H` for each individual in `X`. Missing data in `X`
does not have missing data. Missing data is initialized as 2x alternate allele freq.

# Input
* `X`: `p x n` genotype matrix possibly with missings. Each column is an individual.
* `H`: `p * d` haplotype matrix. Each column is a haplotype.

# Output
* `happair`: optimal haplotype pairs. `X[:, k] ≈ H[:, happair[1][k]] + H[:, happair[2][k]]`.
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
"""
function haplopair!(
    X::AbstractMatrix, # p × n
    H::AbstractMatrix; # p × d
    # preallocated vectors
    happair1::AbstractVector = ones(Int, size(X, 2)), # length n
    happair2::AbstractVector = ones(Int, size(X, 2)), # length n
    hapscore::AbstractVector = Vector{Float32}(undef, size(X, 2)), # length n
    inv_sqrt_allele_var::Union{Nothing, AbstractVector} = nothing, # length p
    # preallocated matrices
    M     :: AbstractMatrix{Float32} = Matrix{Float32}(undef, size(H, 2), size(H, 2)), # cannot be preallocated until Julia 2.0
    Xwork :: AbstractMatrix{Float32} = Matrix{Float32}(undef, size(X, 1), size(X, 2)), # p × n
    Hwork :: AbstractMatrix{Float32} = convert(Matrix{Float32}, H),                    # p × d (not preallocated)
    N     :: AbstractMatrix{Float32} = Matrix{Float32}(undef, size(X, 2), size(H, 2)), # n × d (not preallocated)
    # Hwork :: ElasticArray{Float32} = convert(ElasticArrays{Float32}, H),            # p × d
    # N     :: ElasticArray{Float32} = ElasticArrays{Float32}(undef, size(X, 2), size(H, 2)), # n × d
    )
    p, n  = size(X)
    d     = size(H, 2)

    # reallocate matrices for last window (TODO: Hwork)
    if size(Xwork, 1) != p
        Xwork = zeros(Float32, p, n)
        # Hwork = ElasticArray{Float32}(undef, p, d)
    end

    # resize N
    # ElasticArrays.resize!(N, n, d)
    # ElasticArrays.resize!(Hwork, p, d)
    # copyto!(Hwork, H)

    # initializes missing
    initXfloat!(Xwork, X)

    t2, t3 = haplopair!(Xwork, Hwork, M, N, happair1, happair2, hapscore,
        inv_sqrt_allele_var)
    t1 = t4 = 0.0 # no time spent on haplotype thinning or rescreening

    return t1, t2, t3, t4
end

"""
    haplopair!(X, H, M, N, happair, hapscore)

Calculate the best pair of haplotypes in `H` for each individual in `X`. Overwite
`M` by `M[i, j] = 2dot(H[:, i], H[:, j]) + sumabs2(H[:, i]) + sumabs2(H[:, j])`,
`N` by `2X'H`, `happair` by optimal haplotype pair, and `hapscore` by
objective value from the optimal haplotype pair.

# Input
* `X`: `p x n` genotype matrix. Each column is an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `M`: overwritten by `M[i, j] = 2dot(H[:, i], H[:, j]) + sumabs2(H[:, i]) +
    sumabs2(H[:, j])`.
* `N`: overwritten by `n x d` matrix `2X'H`.
* `happair`: optimal haplotype pair. `X[:, k] ≈ H[:, happair[k, 1]] + H[:, happair[k, 2]]`.
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
"""
function haplopair!(
    X::AbstractMatrix{Float32},
    H::AbstractMatrix{Float32},
    M::AbstractMatrix{Float32},
    N::AbstractMatrix{Float32},
    happair1::AbstractVector{Int32},
    happair2::AbstractVector{Int32},
    hapscore::AbstractVector{Float32},
    inv_sqrt_allele_var::Union{Nothing, AbstractVector}
    )

    p, n, d = size(X, 1), size(X, 2), size(H, 2)

    # assemble M (upper triangular only)
    t2 = @elapsed begin
        if !isnothing(inv_sqrt_allele_var)
            H .*= inv_sqrt_allele_var # wᵢ = 1/√2p(1-p)
        end
        mul!(M, Transpose(H), H)
        for j in 1:d, i in 1:(j - 1) # off-diagonal
            M[i, j] = 2M[i, j] + M[i, i] + M[j, j]
        end
        for j in 1:d # diagonal
            M[j, j] *= 4
        end

        # assemble N
        if !isnothing(inv_sqrt_allele_var)
            H .*= inv_sqrt_allele_var # wᵢ = 1/2p(1-p)
        end
        mul!(N, Transpose(X), H)
        @simd for I in eachindex(N)
            N[I] *= 2
        end
    end

    # computational routine
    t3 = @elapsed haplopair!(happair1, happair2, hapscore, M, N)

    # supplement the constant terms in objective
    t3 += @elapsed begin
        @inbounds for j in 1:n
            @simd for i in 1:p
                hapscore[j] += abs2(X[i, j])
            end
        end
    end

    return t2, t3
end

"""
    haplopair!(happair, hapscore, M, N)

Calculate the best pair of haplotypes pairs in the filtered haplotype panel
for each individual in `X` using sufficient statistics `M` and `N`.

# Note
The best haplotype pairs are column indices of the filtered haplotype panels.

# Input
* `happair`: optimal haplotype pair for each individual.
* `hapmin`: minimum offered by the optimal haplotype pair.
* `M`: `d x d` matrix with entries `M[i, j] = 2dot(H[:, i], H[:, j]) +
    sumabs2(H[:, i]) + sumabs2(H[:, j])`, where `H` is the haplotype matrix
    with haplotypes in columns. Only the upper triangular part of `M` is used.
* `N`: `n x d` matrix `2X'H`, where `X` is the genotype matrix with individuals
    in columns.
"""
function haplopair!(
    happair1::AbstractVector{Int32},
    happair2::AbstractVector{Int32},
    hapmin::AbstractVector{Float32},
    M::AbstractMatrix{Float32},
    N::AbstractMatrix{Float32},
    )

    n, d = size(N)
    fill!(hapmin, Inf32)

    @inbounds for k in 1:d, j in 1:k
        Mjk = M[j, k]
        # loop over individuals
        @simd for i in 1:n
            score = Mjk - N[i, j] - N[i, k]

            # keep best happair (original code)
            if score < hapmin[i]
                hapmin[i], happair1[i], happair2[i] = score, j, k
            end

            # keep all happairs that are equally good
            # if score < hapmin[i]
            #     empty!(happairs[i])
            #     push!(happairs[i], (j, k))
            #     hapmin[i] = score
            # elseif score == hapmin[i]
            #     push!(happairs[i], (j, k))
            # end

            # keep happairs that within some range of best pair (but finding all of them requires a 2nd pass)
            # if score < hapmin[i]
            #     empty!(happairs[i])
            #     push!(happairs[i], (j, k))
            #     hapmin[i] = score
            # elseif score <= hapmin[i] + tol && length(happairs[i]) < 100
            #     push!(happairs[i], (j, k))
            # end

            # keep top 10 haplotype pairs
            # if score < hapmin[i]
            #     length(happairs[i]) == 10 && popfirst!(happairs[i])
            #     push!(happairs[i], (j, k))
            #     hapmin[i] = score
            # elseif score <= hapmin[i] + interval
            #     length(happairs[i]) == 10 && popfirst!(happairs[i])
            #     push!(happairs[i], (j, k))
            # end

            # keep all previous best pairs
            # if score < hapmin[i]
            #     push!(happairs[i], (j, k))
            #     hapmin[i] = score
            # end

            # keep all previous best pairs and equally good pairs
            # if score <= hapmin[i]
            #     push!(happairs[i], (j, k))
            #     hapmin[i] = score
            # end
        end
    end

    return nothing
end

"""
    fillmissing!(Xm, Xwork, H, haplopairs)

Fill in missing genotypes in `X` according to haplotypes. Non-missing genotypes
remain same.

# Input
* `Xm`: `p x n` genotype matrix with missing values. Each column is an individual.
* `Xwork`: `p x n` genotype matrix where missing values are filled with sum of 2 haplotypes.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `happair`: pair of haplotypes. `X[:, k] = H[:, happair[1][k]] + H[:, happair[2][k]]`.
"""
function fillmissing!(
    Xm::AbstractMatrix{Union{U, Missing}},
    Xwork::AbstractMatrix{T},
    H::AbstractMatrix{T},
    happairs::Vector{Vector{Tuple{Int, Int}}},
    ) where {T, U}

    p, n = size(Xm)
    best_discrepancy = typemax(eltype(Xwork))

    for j in 1:n, happair in happairs[j]
        discrepancy = zero(T)
        for i in 1:p
            if ismissing(Xm[i, j])
                tmp = H[i, happair[1]] + H[i, happair[2]]
                discrepancy += abs2(Xwork[i, j] - tmp)
                Xwork[i, j] = tmp
            end
        end
        if discrepancy < best_discrepancy
            best_discrepancy = discrepancy
        end
    end
    return best_discrepancy
end

"""
    initXfloat!(Xfloat, X)

Initializes the matrix `Xfloat` where missing values of matrix `X` by `2 x` allele frequency
and nonmissing entries of `X` are converted to type `Float32` for subsequent BLAS routines.

# Input
* `X` is a `p x n` genotype matrix. Each column is an individual.
* `Xfloat` is the `p x n` matrix of X where missing values are filled by 2x allele frequency.
"""
function initXfloat!(
    Xfloat::AbstractMatrix,
    X::AbstractMatrix
    )

    T = Float32
    p, n = size(X)

    @inbounds for i in 1:p
        # allele frequency
        cnnz = zero(T)
        csum = zero(T)
        for j in 1:n
            if !ismissing(X[i, j])
                cnnz += one(T)
                csum += convert(T, X[i, j])
            end
        end
        # set missing values to 2freq, unless cnnz is 0
        imp = (cnnz == 0 ? zero(T) : csum / cnnz)
        for j in 1:n
            if ismissing(X[i, j])
                Xfloat[i, j] = imp
            else
                Xfloat[i, j] = convert(T, X[i, j])
            end
        end
    end

    any(isnan, Xfloat) && error("Xfloat contains NaN during initialization! Shouldn't happen!")
    any(isinf, Xfloat) && error("Xfloat contains Inf during initialization! Shouldn't happen!")
    any(ismissing, Xfloat) && error("Xfloat contains Missing during initialization! Shouldn't happen!")

    return nothing
end

"""
    chunks(people, haplotypes)

Determines how many windows per chunk will be processed at once based on
estimated memory. Total memory usage will be roughly 80% of total RAM.

# Inputs
- `d`: average number of unique haplotypes per window
- `td`: total number of haplotypes
- `p`: number of typed SNPs per window
- `n`: number of samples
- `threads`: number of threads (this affects `M` and `N` only)
- `Xbytes`: number of bytes to store genotype matrix
- `Hbytes`: number of bytes to store compressed haplotypes

# Output
- Maximum windows per chunk

# Memory intensive items:
- `M`: requires `d × d × 4` bytes per thread
- `N`: requires `d × p × 4` bytes per thread
- `redundant_haplotypes`: requires `windows × 2td × n` bits where `windows` is number of windows per chunk
"""
function nchunks(
    d::Int,
    td::Int,
    p::Int,
    n::Int,
    threads::Int = Threads.nthreads(),
    Xbytes::Int = 0,
    compressed_Hunique::Union{Nothing, CompressedHaplotypes} = nothing
    )
    # system info
    system_memory_gb = Sys.total_memory() / 2^30
    system_memory_bits = 8000000000 * system_memory_gb
    usable_bits = round(Int, system_memory_bits * 0.8) # use 80% of total memory

    # estimate memory usage per window
    Mbits_per_win = 32d * d * threads
    Nbits_per_win = 32d * p * threads
    Rbits_per_win = 2 * td * n

    # calculate X and H's memory requirement in bits
    Xbits = 4Xbytes
    Hbits = 0
    if !isnothing(compressed_Hunique)
        # avoid computing sizes for vector of strings because they are slow
        Hbits += Base.summarysize(compressed_Hunique.CW)
        Hbits += Base.summarysize(compressed_Hunique.CW_typed)
        Hbits += Base.summarysize(compressed_Hunique.start)
        Hbits += Base.summarysize(compressed_Hunique.pos)
        Hbits += Base.summarysize(compressed_Hunique.altfreq)
    end

    return round(Int, (usable_bits - Hbits - Xbits - Nbits_per_win - Mbits_per_win) / Rbits_per_win)
end
