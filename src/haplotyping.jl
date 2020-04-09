"""
    phase(tgtfile, reffile, outfile; impute = true, width = 1200)

Phasing (haplotying) of `tgtfile` from a pool of haplotypes `reffile`
by sliding windows and saves result in `outfile`. 

# Input
- `reffile`: VCF file with reference genotype (GT) data
- `tgtfile`: VCF file with target genotype (GT) data
- `outfile`: the prefix for output filenames. Will not be generated if `impute` is false
- `width`  : number of SNPs (markers) in each sliding window. 
- `flankwidth`: Number of SNPs flanking the sliding window (defaults to 10% of `width`)
- `fast_method`: If `true`, will use window-by-window intersection for phasing. If `false`, phasing uses dynamic progrmaming. 
"""
function phase(
    tgtfile::AbstractString,
    reffile::AbstractString;
    outfile::AbstractString = "imputed." * tgtfile,
    width::Int = 400,
    flankwidth::Int = round(Int, 0.1width),
    fast_method::Bool = false,
    )

    # declare some constants
    snps, H_snps = nrecords(tgtfile), nrecords(reffile)
    snps == H_snps || error("Number of SNPs in X = $snps does not equal SNPs in H = $H_snps. Run conformgt in VCFTools first.")
    people = nsamples(tgtfile)
    haplotypes = 2nsamples(reffile)
    windows = floor(Int, snps / width)
    chunks = ceil(Int, snps / 1e5) # max 100k snps per chunk
    snps_per_chunk = ceil(Int, snps / chunks)
    ph = [HaplotypeMosaicPair(snps) for i in 1:people] # phase information

    # convert vcf files to numeric matrices
    Xreader = VCF.Reader(openvcf(tgtfile, "r"))
    Hreader = VCF.Reader(openvcf(reffile, "r"))

    if chunks > 1
        X = Matrix{Union{Float32, Missing}}(undef, snps_per_chunk, people)
        H = BitArray{2}(undef, snps_per_chunk, haplotypes)

        # phase chunk by chunk
        for chunk in 1:(chunks - 1)
            @info "Running chunk $chunk / $chunks"

            # copy current chunk's sample data into X and reference panels into H
            copy_gt_trans!(X, Xreader, msg = "Importing genotype file...")
            copy_ht_trans!(H, Hreader, msg = "Importing reference haplotype files...")
            
            # compute redundant haplotype sets
            hs = compute_optimal_halotype_set(X, H, width=width, flankwidth=flankwidth, fast_method=fast_method)

            # phase (haplotyping) current chunk
            offset = (chunk - 1) * snps_per_chunk
            if fast_method
                phase_fast!(ph, X, H, hs, width=width, flankwidth=flankwidth, chunk_offset=offset)
            else
                phase!(ph, X, H, hs, width=width, flankwidth=flankwidth, chunk_offset=offset)
            end
        end
    end

    # phase last chunk
    @info "Running chunk $chunks / $chunks"
    remaining_snps = snps - ((chunks - 1) * snps_per_chunk)
    X = Matrix{Union{Float32, Missing}}(undef, remaining_snps, people)
    H = BitArray{2}(undef, remaining_snps, haplotypes)
    copy_gt_trans!(X, Xreader, msg = "Importing genotype file...")
    copy_ht_trans!(H, Hreader, msg = "Importing reference haplotype files...")
    
    # compute redundant haplotype sets
    hs = compute_optimal_halotype_set(X, H, width = width, flankwidth=flankwidth, fast_method=fast_method)

    # phase (haplotyping) current chunk
    offset = (chunks - 1) * snps_per_chunk
    if fast_method
        phase_fast!(ph, X, H, hs, width=width, flankwidth=flankwidth, chunk_offset=offset)
    else
        phase!(ph, X, H, hs, width=width, flankwidth=flankwidth, chunk_offset=offset)
    end
    close(Xreader); close(Hreader)

    # create VCF reader and writer
    reader = VCF.Reader(openvcf(tgtfile, "r"))
    writer = VCF.Writer(openvcf(outfile, "w"), header(reader))
    pmeter = Progress(nrecords(tgtfile), 1, "Writing to file...")

    # loop over each record (snp)
    snps, people = size(X, 1), size(X, 2)
    for (i, record) in enumerate(reader)
        gtkey = VCF.findgenokey(record, "GT")
        if !isnothing(gtkey) 
            # loop over samples
            for (j, geno) in enumerate(record.genotype)
                # if missing = '.' = 0x2e
                if record.data[geno[gtkey][1]] == 0x2e
                    #find where snp is located in phase
                    hap1_position = searchsortedlast(ph[j].strand1.start, i)
                    hap2_position = searchsortedlast(ph[j].strand2.start, i)

                    #find the correct haplotypes 
                    hap1 = ph[j].strand1.haplotypelabel[hap1_position]
                    hap2 = ph[j].strand2.haplotypelabel[hap2_position]

                    # save actual allele to data. "0" (REF) => 0x30, "1" (ALT) => 0x31
                    a1, a2 = convert(Bool, H[i, hap1]), convert(Bool, H[i, hap2])
                    record.data[geno[gtkey][1]] = ifelse(a1, 0x31, 0x30)
                    record.data[geno[gtkey][2]] = 0x7c # phased data has separator '|'
                    record.data[geno[gtkey][3]] = ifelse(a2, 0x31, 0x30)
                end
            end
        end
        write(writer, record)
        next!(pmeter) #update progress
    end

    # close 
    flush(writer); close(reader); close(writer)

    return hs, ph
end

"""
    phase(X, H, width=400, verbose=true)

Phasing (haplotying) of genotype matrix `X` from a pool of haplotypes `H`
by dynamic programming. A precomputed, window-by-window haplotype pairs is assumed. 

# Input
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `width`: width of the sliding window.
* `verbose`: display algorithmic information.
"""
function phase!(
    ph::Vector{HaplotypeMosaicPair},
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix,
    hapset::Vector{Vector{Vector{Tuple{Int, Int}}}};
    width::Int = 400,
    flankwidth::Int = round(Int, 0.1width),
    chunk_offset::Int = 0,
    Xtrue::Union{AbstractMatrix, Nothing} = nothing, # for testing
    ) where T <: Real

    # allocate working arrays
    Tu       = Tuple{Int, Int}
    Pu       = Tuple{Float64, Tu}
    sol_path = [Vector{Tuple{Int, Int}}(undef, windows) for i in 1:Threads.nthreads()]
    nxt_pair = [[Int[] for i in 1:windows] for i in 1:Threads.nthreads()]
    tree_err = [[Float64[] for i in 1:windows] for i in 1:Threads.nthreads()]
    pmeter   = Progress(people, 5, "Imputing samples...")

    # loop over each person
    Threads.@threads for i in 1:people
        verbose && @info "imputing person $i"

        # first find optimal haplotype pair in each window using dynamic programming
        id = Threads.threadid()
        connect_happairs!(sol_path[id], nxt_pair[id], tree_err[id], hapset[i], λ = 1.0)

        # phase first window 
        push!(ph[i].strand1.start, 1)
        push!(ph[i].strand1.haplotypelabel, sol_path[id][1][1])
        push!(ph[i].strand2.start, 1)
        push!(ph[i].strand2.haplotypelabel, sol_path[id][1][2])

        # phase middle windows
        for w in 2:(windows - 1)
            Xwi = view(X, ((w - 2) * width + 1):(w * width), i)
            Hw  = view(H, ((w - 2) * width + 1):(w * width), :)
            sol_path[id][w], bkpts = continue_haplotype(Xwi, Hw, sol_path[id][w - 1], sol_path[id][w])

            # strand 1
            if bkpts[1] > -1 && bkpts[1] < 2width
                push!(ph[i].strand1.start, chunk_offset + (w - 2) * width + 1 + bkpts[1])
                push!(ph[i].strand1.haplotypelabel, sol_path[id][w][1])
            end
            # strand 2
            if bkpts[2] > -1 && bkpts[2] < 2width
                push!(ph[i].strand2.start, chunk_offset + (w - 2) * width + 1 + bkpts[2])
                push!(ph[i].strand2.haplotypelabel, sol_path[id][w][2])
            end
        end

        # phase last window
        Xwi = view(X, ((windows - 2) * width + 1):snps, i)
        Hw  = view(H, ((windows - 2) * width + 1):snps, :)
        sol_path[id][windows], bkpts = continue_haplotype(Xwi, Hw, sol_path[id][windows - 1], sol_path[id][windows])
        # strand 1
        if bkpts[1] > -1 && bkpts[1] < 2width
            push!(ph[i].strand1.start, chunk_offset + (windows - 2) * width + 1 + bkpts[1])
            push!(ph[i].strand1.haplotypelabel, sol_path[id][windows][1])
        end
        # strand 2
        if bkpts[2] > -1 && bkpts[2] < 2width
            push!(ph[i].strand2.start, chunk_offset + (windows - 2) * width + 1 + bkpts[2])
            push!(ph[i].strand2.haplotypelabel, sol_path[id][windows][2])
        end
        next!(pmeter) #update progress
    end
end

function phase_fast!(
    ph::Vector{HaplotypeMosaicPair},
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix,
    hapset::Vector{OptimalHaplotypeSet};
    width::Int = 400,
    flankwidth::Int = round(Int, 0.1width),
    chunk_offset::Int = 0,
    Xtrue::Union{AbstractMatrix, Nothing} = nothing, # for testing
    ) where T <: Real

    # declare some constants
    snps, people = size(X)
    haplotypes = size(H, 2)
    windows = floor(Int, snps / width)

    # allocate working arrays
    haplo_chain = ([copy(hapset[i].strand1[1]) for i in 1:people], [copy(hapset[i].strand2[1]) for i in 1:people])
    chain_next  = (BitVector(undef, haplotypes), BitVector(undef, haplotypes))
    window_span = (ones(Int, people), ones(Int, people))
    pmeter      = Progress(people, 1, "Intersecting haplotypes...")

    # begin intersecting haplotypes window by window
    @inbounds for i in 1:people
        for w in 2:windows
            # Decide whether to cross over based on the larger intersection
            # A   B      A   B
            # |   |  or    X
            # C   D      C   D
            chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w] # not crossing over
            chain_next[2] .= haplo_chain[1][i] .& hapset[i].strand2[w] # crossing over
            AC = sum(chain_next[1])
            AD = sum(chain_next[2])
            chain_next[1] .= haplo_chain[2][i] .& hapset[i].strand1[w] # crossing over
            chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w] # not crossing over
            BC = sum(chain_next[1])
            BD = sum(chain_next[2])
            if AC + BD < AD + BC
                hapset[i].strand1[w], hapset[i].strand2[w] = hapset[i].strand2[w], hapset[i].strand1[w]
            end

            # intersect all surviving haplotypes with next window
            chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w]
            chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w]

            # strand 1 becomes empty
            if sum(chain_next[1]) == 0
                # delete all nonmatching haplotypes in previous windows
                for ww in (w - window_span[1][i]):(w - 1)
                    hapset[i].strand1[ww] .= haplo_chain[1][i]
                end

                # reset counters and storage
                haplo_chain[1][i] .= hapset[i].strand1[w]
                window_span[1][i] = 1
            else
                haplo_chain[1][i] .= chain_next[1]
                window_span[1][i] += 1
            end

            # strand 2 becomes empty
            if sum(chain_next[2]) == 0
                # delete all nonmatching haplotypes in previous windows
                for ww in (w - window_span[2][i]):(w - 1)
                    hapset[i].strand2[ww] .= haplo_chain[2][i]
                end

                # reset counters and storage
                haplo_chain[2][i] .= hapset[i].strand2[w]
                window_span[2][i] = 1
            else
                haplo_chain[2][i] .= chain_next[2]
                window_span[2][i] += 1
            end
        end
        next!(pmeter) #update progress
    end

    # handle last few windows separately, since intersection may not become empty
    for i in 1:people
        for ww in (windows - window_span[1][i] + 1):windows
            hapset[i].strand1[ww] .= haplo_chain[1][i]
        end

        for ww in (windows - window_span[2][i] + 1):windows
            hapset[i].strand2[ww] .= haplo_chain[2][i]
        end
    end

    # phase window 1
    for i in 1:people
        hap1 = findfirst(hapset[i].strand1[1]) :: Int64
        hap2 = findfirst(hapset[i].strand2[1]) :: Int64
        push!(ph[i].strand1.start, 1 + chunk_offset)
        push!(ph[i].strand1.haplotypelabel, hap1)
        push!(ph[i].strand2.start, 1 + chunk_offset)
        push!(ph[i].strand2.haplotypelabel, hap2)
    end

    # find optimal break points and record info to phase. 
    pmeter = Progress(people, 5, "Merging breakpoints...")
    strand1_intersect = [copy(chain_next[1]) for i in 1:Threads.nthreads()]
    strand2_intersect = [copy(chain_next[2]) for i in 1:Threads.nthreads()]
    Threads.@threads for i in 1:people
        id = Threads.threadid()
        for w in 2:windows
            Hi = view(H, ((w - 2) * width + 1):(w * width), :)
            Xi = view(X, ((w - 2) * width + 1):(w * width), i)
            strand1_intersect[id] .= hapset[i].strand1[w - 1] .& hapset[i].strand1[w]
            strand2_intersect[id] .= hapset[i].strand2[w - 1] .& hapset[i].strand2[w]
            # double haplotype switch
            if sum(strand1_intersect[id]) == sum(strand2_intersect[id]) == 0
                s1_prev = ph[i].strand1.haplotypelabel[end]
                s2_prev = ph[i].strand2.haplotypelabel[end]
                # search breakpoints when choosing first pair
                s1_next = findfirst(hapset[i].strand1[w]) :: Int64
                s2_next = findfirst(hapset[i].strand2[w]) :: Int64
                bkpt, err_optim = search_breakpoint(Xi, Hi, (s1_prev, s1_next), (s2_prev, s2_next))
                # record info into phase
                push!(ph[i].strand1.start, chunk_offset + (w - 2) * width + 1 + bkpt[1])
                push!(ph[i].strand2.start, chunk_offset + (w - 2) * width + 1 + bkpt[2])
                push!(ph[i].strand1.haplotypelabel, s1_next)
                push!(ph[i].strand2.haplotypelabel, s2_next)
            # single haplotype switch
            elseif sum(strand1_intersect[id]) == 0
                # search breakpoints among all possible haplotypes
                s1_prev = ph[i].strand1.haplotypelabel[end]
                s1_win_next = findall(hapset[i].strand1[w])
                s2_win_next = findall(hapset[i].strand2[w])
                best_bktp = 0
                best_err  = typemax(Int)
                best_s1_next = 0
                for s1_next in s1_win_next, s2_next in s2_win_next
                    bkpt, err_optim = search_breakpoint(Xi, Hi, s2_next, (s1_prev, s1_next))
                    if err_optim < best_err
                        best_bktp, best_err, best_s1_next = bkpt, err_optim, s1_next
                    end
                end
                # record info into phase
                push!(ph[i].strand1.start, chunk_offset + (w - 2) * width + 1 + best_bktp)
                push!(ph[i].strand1.haplotypelabel, best_s1_next)
            # single haplotype switch
            elseif sum(strand2_intersect[id]) == 0
                # search breakpoints among all possible haplotypes
                s2_prev = ph[i].strand2.haplotypelabel[end]
                s2_win_next = findall(hapset[i].strand2[w])
                s1_win_next = findall(hapset[i].strand1[w])
                best_bktp = 0
                best_err  = typemax(Int)
                best_s2_next = 0
                for s2_next in s2_win_next, s1_next in s1_win_next
                    bkpt, err_optim = search_breakpoint(Xi, Hi, s1_next, (s2_prev, s2_next))
                    if err_optim < best_err
                        best_bktp, best_err, best_s2_next = bkpt, err_optim, s2_next
                    end
                end
                # record info into phase
                push!(ph[i].strand2.start, chunk_offset + (w - 2) * width + 1 + best_bktp)
                push!(ph[i].strand2.haplotypelabel, best_s2_next)
            end
        end
        next!(pmeter) #update progress
    end
end

"""
    impute!(X, H, phase)

Imputes `X` completely using segments of haplotypes `H` where segments are stored in `phase`. 
Non-missing entries in `X` can be different after imputation. 
"""
function impute!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair}
    )

    fill!(X, 0)
    # loop over individuals
    for i in 1:size(X, 2)
        for s in 1:(length(phase[i].strand1.start) - 1)
            idx = phase[i].strand1.start[s]:(phase[i].strand1.start[s + 1] - 1)
            X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[s]]
        end
        idx = phase[i].strand1.start[end]:phase[i].strand1.length
        X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[end]]
        for s in 1:(length(phase[i].strand2.start) - 1)
            idx = phase[i].strand2.start[s]:(phase[i].strand2.start[s + 1] - 1)
            X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[s]]
        end
        idx = phase[i].strand2.start[end]:phase[i].strand2.length
        X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[end]]
    end
end

"""
    impute2!(X, H, phase)

Imputes missing entries of `X` using corresponding haplotypes `H` via `phase` information. 
Non-missing entries in `X` will not change. 
"""
function impute2!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair}
    )

    p, n = size(X)

    @inbounds for snp in 1:p, person in 1:n
        if ismissing(X[snp, person])
            #find where snp is located in phase
            hap1_position = searchsortedlast(phase[person].strand1.start, snp)
            hap2_position = searchsortedlast(phase[person].strand2.start, snp)

            #find the correct haplotypes 
            hap1 = phase[person].strand1.haplotypelabel[hap1_position]
            hap2 = phase[person].strand2.haplotypelabel[hap2_position]

            # imputation step 
            X[snp, person] = H[snp, hap1] + H[snp, hap2]
        end
    end

    return nothing
end
