"""
    phase(tgtfile, reffile, outfile; impute = true, width = 1200)

Phasing (haplotying) of `tgtfile` from a pool of haplotypes `reffile`
by sliding windows and saves result in `outfile`. By default, we will perform
imputation after phasing and window width is 700.


# Input
- `reffile`: VCF file with reference genotype (GT) data
- `tgtfile`: VCF file with target genotype (GT) data
- `impute` : true = imputes missing genotypes with phase information.
- `outfile`: the prefix for output filenames. Will not be generated if `impute` is false
- `width`  : number of SNPs (markers) in each sliding window. 
"""
function phase(
    tgtfile::AbstractString,
    reffile::AbstractString;
    impute::Bool = true,
    outfile::AbstractString = "imputed." * tgtfile,
    width::Int = 1200
    )
    # convert vcf files to numeric matrices
    X = convert_gt(Float32, tgtfile)
    H = convert_ht(Float32, reffile)

    # compute redundant haplotype sets. 
    X = copy(X')
    H = copy(H')
    hs = compute_optimal_halotype_set(X, H, width = width, verbose = false)

    # phasing (haplotyping)
    ph = phase(X, H, hapset = hs, width = width, verbose = false)

    if impute
        # imputation without changing known entries
        # impute2!(X, H, ph)

        # create VCF reader and writer
        reader = VCF.Reader(openvcf(tgtfile, "r"))
        writer = VCF.Writer(openvcf(outfile, "w"), header(reader))

        # loop over each record
        for (i, record) in enumerate(reader)
            gtkey = VCF.findgenokey(record, "GT")
            _, _, _, _, _, _, _, _, minor_allele, _, _ = gtstats(record, nothing)
            if !isnothing(gtkey) 
                # loop over genotypes
                for (j, geno) in enumerate(record.genotype)
                    # if missing = '.' = 0x2e
                    if record.data[geno[gtkey][1]] == 0x2e
                        #find where snp is located in phase
                        hap1_position = searchsortedlast(ph[j].strand1.start, i)
                        hap2_position = searchsortedlast(ph[j].strand2.start, i)

                        #find the correct haplotypes 
                        hap1 = ph[j].strand1.haplotypelabel[hap1_position]
                        hap2 = ph[j].strand2.haplotypelabel[hap2_position]

                        # actual allele
                        a1 = convert(Bool, H[i, hap1])
                        a2 = convert(Bool, H[i, hap2])

                        # TODO: what should below be?
                        # record.data[geno[gtkey][1]] = ht_to_UInt8(a1, minor_allele)
                        # record.data[geno[gtkey][3]] = ht_to_UInt8(a2, minor_allele)
                        record.data[geno[gtkey][1]] = ifelse(a1, 0x31, 0x30)
                        record.data[geno[gtkey][3]] = ifelse(a2, 0x31, 0x30)
                    end
                end
            end
            write(writer, record)
        end

        # close 
        flush(writer); close(reader); close(writer)
    end

    return hs, ph
end

function ht_to_UInt8(
    a::Bool,
    minor_allele::Bool
    ) where T <: Real
    if minor_allele # REF is the minor allele
        return 0x30 # '0'
    else # ALT is the minor allele
        return 0x31 # '1'
    end
end

"""
    phase(X, H, width=400, verbose=true)

Phasing (haplotying) of genotype matrix `X` from a pool of haplotypes `H`
by sliding windows.

# Input
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `width`: width of the sliding window.
* `verbose`: display algorithmic information.
"""
function phase(
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix{T};
    hapset::Union{Vector{OptimalHaplotypeSet}, Nothing} = nothing,
    width::Int    = 700,
    verbose::Bool = true
    ) where T <: Real

    # declare some constants
    snps, people = size(X)
    haplotypes = size(H, 2)
    windows = floor(Int, snps / width)

    # compute redundant haplotype sets. 
    if isnothing(hapset)
        hapset = compute_optimal_halotype_set(X, H, width=width, verbose=verbose)
    end

    # allocate working arrays
    phase = [HaplotypeMosaicPair(snps) for i in 1:people]
    haplo_chain = ([copy(hapset[i].strand1[1]) for i in 1:people], [copy(hapset[1].strand2[1]) for i in 1:people])
    chain_next  = (BitVector(undef, haplotypes), BitVector(undef, haplotypes))
    window_span = (ones(Int, people), ones(Int, people))

    # TODO: parallel computing
    # begin intersecting haplotypes window by window 
    @inbounds for i in 1:people, w in 2:windows

        # decide whether to cross over based on the larger intersection
        chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w] # not crossing over
        chain_next[2] .= haplo_chain[1][i] .& hapset[i].strand2[w] # crossing over
        if sum(chain_next[1]) < sum(chain_next[2])
            hapset[i].strand1[w], hapset[i].strand2[w] = hapset[i].strand2[w], hapset[i].strand1[w]
        end        

        # strand 1 
        chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w]
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

        # strand 2
        chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w]
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
        push!(phase[i].strand1.start, 1)
        push!(phase[i].strand1.haplotypelabel, hap1)
        push!(phase[i].strand2.start, 1)
        push!(phase[i].strand2.haplotypelabel, hap2)
    end

    # find optimal break points and record info to phase. 
    # TODO: handle last window separately since view() on X or H is not complete
    strand1_intersect = chain_next[1]
    strand2_intersect = chain_next[2]
    for i in 1:people, w in 2:windows
        
        strand1_intersect .= hapset[i].strand1[w - 1] .& hapset[i].strand1[w]
        if sum(strand1_intersect) == 0
            # search breakpoints
            Xi = view(X, ((w - 2) * width + 1):(w * width), i)
            Hi = view(H, ((w - 2) * width + 1):(w * width), :)
            s2 = findfirst(hapset[i].strand2[w]) :: Int64
            s1_cur  = findfirst(hapset[i].strand1[w - 1]) :: Int64
            s1_next = findfirst(hapset[i].strand1[w]) :: Int64
            bkpt, err_optim = search_breakpoint(Xi, Hi, s2, (s1_cur, s1_next))

            # record info into phase
            push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpt)
            push!(phase[i].strand1.haplotypelabel, s1_next)
        end

        strand2_intersect .= hapset[i].strand2[w - 1] .& hapset[i].strand2[w]
        if sum(strand2_intersect) == 0
            # search breakpoints
            Xi = view(X, ((w - 2) * width + 1):(w * width), i)
            Hi = view(H, ((w - 2) * width + 1):(w * width), :)
            s1 = findfirst(hapset[i].strand1[w]) :: Int64
            s2_cur  = findfirst(hapset[i].strand2[w - 1]) :: Int64
            s2_next = findfirst(hapset[i].strand2[w]) :: Int64
            bkpt, err_optim = search_breakpoint(Xi, Hi, s1, (s2_cur, s2_next))

            # record info into phase
            push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpt)
            push!(phase[i].strand2.haplotypelabel, s2_next)
        end
    end

    return phase 
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

    @inbounds for person in 1:n, snp in 1:p
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
