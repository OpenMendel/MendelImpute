###### This file is part of the MendelImpute.jl package.
###### It contains relevant code to impute and output a genotype matrix

"""
    write(outfile, X, compressed_haplotypes, X_sampleID, XtoH_idx)

Writes imputed `X` into `outfile`. All genotypes in `outfile` are non-missing.

# Inputs
- `outfile`: Output file name (ending in `.vcf.gz` or `.vcf`)
- `X`: Imputed matrix. If `X` is a matrix, output VCF will be unphased. Otherwise if `X` is a Tuple
    of matrix (i.e. `X = X1 + X2`), then all output will be phased. 
- `compressed_Hunique`: A `CompressedHaplotypes` object
- `X_sampleID`: Sample ID of imputation target
- `snp_score`: Imputation score for each typed SNP. `1` is best, `0` is worse
- `XtoH_idx`: Vector aligning typed SNPs with all SNPs in reference panel

# Notes
Here the writing routine is emulating `write_dlm` in Base at 
https://github.com/JuliaLang/julia/blob/3608c84e6093594fe86923339fc315231492484c/stdlib/DelimitedFiles/src/DelimitedFiles.jl#L736
"""
function Base.write(
    outfile::AbstractString,
    X::Union{AbstractMatrix, Tuple{AbstractMatrix, AbstractMatrix}},
    compressed_haplotypes::CompressedHaplotypes,
    X_sampleID::AbstractVector,
    snp_score::AbstractVector,
    XtoH_idx::Union{Nothing, AbstractVector} = nothing,
    )
    threads = Threads.nthreads()
    snps = typeof(X) <: AbstractMatrix ? size(X, 1) : size(X[1], 1)
    len = div(snps, threads)
    files = ["tmp$i.vcf.gz" for i in 1:threads]

    # retrieve reference file information
    chr = (isnothing(XtoH_idx) ? compressed_haplotypes.chr : 
                                 compressed_haplotypes.chr[XtoH_idx])
    pos = (isnothing(XtoH_idx) ? compressed_haplotypes.pos : 
                                 compressed_haplotypes.pos[XtoH_idx])
    ids = (isnothing(XtoH_idx) ? compressed_haplotypes.SNPid : 
                                 compressed_haplotypes.SNPid[XtoH_idx])
    ref = (isnothing(XtoH_idx) ? compressed_haplotypes.refallele : 
                                 compressed_haplotypes.refallele[XtoH_idx])
    alt = (isnothing(XtoH_idx) ? compressed_haplotypes.altallele : 
                                 compressed_haplotypes.altallele[XtoH_idx])

    # write minimal meta information to outfile
    io = [openvcf(files[i], "w") for i in 1:threads]
    pb = [PipeBuffer() for _ in 1:threads]
    print(pb[1], "##fileformat=VCFv4.2\n")
    print(pb[1], "##source=MendelImpute\n")
    print(pb[1], "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n")
    print(pb[1], "##INFO=<ID=IMPQ,Number=0,Type=Float,Description=" * 
        "\"Quality of imputed marker. 1 is best, 0 is worse. Only present for typed SNPs\">\n")

    # header line should match reffile (i.e. sample ID's should match)
    print(pb[1], "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT")
    for id in X_sampleID
        print(pb[1], "\t", id)
    end
    print(pb[1], "\n")
    bytesavailable(pb[1]) > 1048576 && write(io[1], take!(pb[1]))

    # each thread writes `len` SNPs
    pmeter = Progress(snps, 5, "Writing to file...")
    Threads.@threads for t in 1:threads
        id = Threads.threadid()
        cur_ranges = (id == threads ? 
            ((threads-1)*len+1:snps) : (1:len) .+ (t-1)*len)

        @inbounds for i in cur_ranges
            # write meta info (chrom/pos/snpid/ref/alt/imputation-quality)
            print(pb[id], chr[i], "\t", string(pos[i]), "\t", ids[i][1], "\t", 
                ref[i], "\t", alt[i][1], "\t.\tPASS\t")
            ismissing(snp_score[i]) ? print(pb[id], ".\tGT") : 
                print(pb[id], "IMPQ=", round(snp_score[i], digits=3), "\tGT")
            # print ith record
            write_snp!(pb[id], X, i) 
            bytesavailable(pb[id]) > 1048576 && write(io[id], take!(pb[id]))
            next!(pmeter)
        end
        write(io[id], take!(pb[id]))
    end
    close.(io); close.(pb) # close io and buffer

    # concatenate all files into 1 VCF file
    run(pipeline(`cat $files`, stdout=outfile))

    # delete intermediate files
    for i in 1:threads
        rm("tmp$i.vcf.gz", force=true)
    end

    return nothing
end

"""
Helper function for saving a record (SNP), not tracking phase information.
"""
function write_snp!(pb::IOBuffer, X::AbstractMatrix, i::Int)
    x = @view(X[i, :]) # current record
    n = length(x)
    @inbounds for j in 1:n
        if x[j] == 0
            print(pb, "\t0/0")
        elseif x[j] == 1
            print(pb, "\t1/0")
        elseif x[j] == 2
            print(pb, "\t1/1")
        else
            error("imputed genotypes can only be 0, 1, 2 but got $(x[j])")
        end
    end
    print(pb, "\n")
    nothing
end

"""
Helper function for saving a record (SNP), tracking phase information.
Here `X = X1 + X2`. 
"""
function write_snp!(pb::IOBuffer, X::Tuple{AbstractMatrix, AbstractMatrix}, i::Int)
    X1, X2 = X[1], X[2]
    x1 = @view(X1[i, :])
    x2 = @view(X2[i, :])

    n = length(x1)
    @assert n == length(x2)
    @inbounds for j in 1:n
        if x1[j] == x2[j] == 0
            print(pb, "\t0|0")
        elseif x1[j] == 0 && x2[j] == 1
            print(pb, "\t0|1")
        elseif x1[j] == 1 && x2[j] == 0
            print(pb, "\t1|0")
        elseif x1[j] == 1 && x2[j] == 1
            print(pb, "\t1|1")
        else
            error("phased genotypes can only be 0|0, 0|1, 1|0 or 1|1 but
                got $(x1[j])|$(x2[j])")
        end
    end
    print(pb, "\n")
    nothing
end

"""
    impute!(X1, X2, H, phase, [impute_untyped])

Imputes `X = X1 + X2` completely using haplotype segments of `H`, where segments
information are stored in `phase`. `X1` is strand1 and `X2` is strand 2. If 
`impute_untyped=false`, untyped SNPs will not be imputed. 

Non-missing entries in `X` can be different after imputation.
"""
function impute!(
    X1::AbstractMatrix,
    X2::AbstractMatrix,
    compressed_Hunique::CompressedHaplotypes,
    phase::Vector{HaplotypeMosaicPair},
    impute_untyped::Bool=true
    )

    fill!(X1, 0)
    fill!(X2, 0)

    # loop over individuals
    for i in 1:size(X1, 2)
        # strand 1
        for s in 1:(length(phase[i].strand1.start) - 1) # first w-1 windows
            X_idx = phase[i].strand1.start[s]:(phase[i].strand1.start[s + 1] - 1)
            w = phase[i].strand1.window[s]
            H = impute_untyped ? compressed_Hunique.CW[w].uniqueH : 
                compressed_Hunique.CW_typed[w].uniqueH
            H_start = impute_untyped ? (abs(phase[i].strand1.start[s] - 
                compressed_Hunique.Hstart[w]) + 1) : 1
            H_idx = H_start:(H_start + length(X_idx) - 1)
            X1[X_idx, i] = H[H_idx, phase[i].strand1.haplotypelabel[s]]
        end
        w = phase[i].strand1.window[end] # last window
        X_end = impute_untyped ? phase[i].strand1.length : size(X1, 1)
        X_idx = phase[i].strand1.start[end]:X_end
        H_start = impute_untyped ? (abs(phase[i].strand1.start[end] - 
            compressed_Hunique.Hstart[w]) + 1) : 1
        H_idx = H_start:(H_start + length(X_idx) - 1)
        H = impute_untyped ? compressed_Hunique.CW[w].uniqueH : 
            compressed_Hunique.CW_typed[w].uniqueH
        X1[X_idx, i] = H[H_idx, phase[i].strand1.haplotypelabel[end]]

        # strand 2
        for s in 1:(length(phase[i].strand2.start) - 1) # first w-1 windows
            X_idx = phase[i].strand2.start[s]:(phase[i].strand2.start[s + 1] - 1)
            w = phase[i].strand2.window[s]
            H = impute_untyped ? compressed_Hunique.CW[w].uniqueH : 
                compressed_Hunique.CW_typed[w].uniqueH
            H_start = impute_untyped ? (abs(phase[i].strand2.start[s] - 
                compressed_Hunique.Hstart[w]) + 1) : 1
            H_idx = H_start:(H_start + length(X_idx) - 1)
            X2[X_idx, i] = H[H_idx, phase[i].strand2.haplotypelabel[s]]
        end
        w = phase[i].strand2.window[end] # last window
        X_end = impute_untyped ? phase[i].strand1.length : size(X2, 1)
        X_idx = phase[i].strand2.start[end]:X_end
        H = impute_untyped ? compressed_Hunique.CW[w].uniqueH : 
            compressed_Hunique.CW_typed[w].uniqueH
        H_start = impute_untyped ? (abs(phase[i].strand2.start[end] - 
            compressed_Hunique.Hstart[w]) + 1) : 1
        H_idx = H_start:(H_start + length(X_idx) - 1)
        X2[X_idx, i] = H[H_idx, phase[i].strand2.haplotypelabel[end]]
    end
end

function impute!(
    X1::AbstractMatrix,
    X2::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair},
    )

    fill!(X1, 0)
    fill!(X2, 0)

    # loop over individuals
    for i in 1:size(X1, 2)
        for s in 1:(length(phase[i].strand1.start) - 1)
            idx = phase[i].strand1.start[s]:(phase[i].strand1.start[s + 1] - 1)
            X1[idx, i] = H[idx, phase[i].strand1.haplotypelabel[s]]
        end
        idx = phase[i].strand1.start[end]:phase[i].strand1.length
        X1[idx, i] = H[idx, phase[i].strand1.haplotypelabel[end]]
        for s in 1:(length(phase[i].strand2.start) - 1)
            idx = phase[i].strand2.start[s]:(phase[i].strand2.start[s + 1] - 1)
            X2[idx, i] += H[idx, phase[i].strand2.haplotypelabel[s]]
        end
        idx = phase[i].strand2.start[end]:phase[i].strand2.length
        X2[idx, i] += H[idx, phase[i].strand2.haplotypelabel[end]]
    end
end

"""
    impute_discard_phase!(X, H, phase, [impute_untyped])

Imputes missing entries of `X` using corresponding haplotypes `H` via `phase`
information. Non-missing entries in `X` will not change, but X and H has to be
aligned. This does NOT preserve phase information.
"""
function impute_discard_phase!(
    X::AbstractMatrix,
    compressed_Hunique::CompressedHaplotypes,
    phase::Vector{HaplotypeMosaicPair},
    impute_untyped::Bool=true
    )

    p, n = size(X)

    # for person in 1:n
    Threads.@threads for person in 1:n
        @inbounds for snp in 1:p
            if ismissing(X[snp, person])
                #find which segment the snp is located
                hap1_segment = searchsortedlast(phase[person].strand1.start,snp)
                hap2_segment = searchsortedlast(phase[person].strand2.start,snp)

                #find haplotype pair in corresponding window for this segment
                h1 = phase[person].strand1.haplotypelabel[hap1_segment]
                h2 = phase[person].strand2.haplotypelabel[hap2_segment]
                w1 = phase[person].strand1.window[hap1_segment]
                w2 = phase[person].strand2.window[hap2_segment]
                i1 = snp - compressed_Hunique.Hstart[w1] + 1
                i2 = snp - compressed_Hunique.Hstart[w2] + 1

                # imputation step
                H1 = impute_untyped ? compressed_Hunique.CW[w1].uniqueH : 
                    compressed_Hunique.CW_typed[w1].uniqueH
                H2 = impute_untyped ? compressed_Hunique.CW[w2].uniqueH : 
                    compressed_Hunique.CW_typed[w2].uniqueH
                X[snp, person] = H1[i1, h1] + H2[i2, h2]
            end
        end
    end

    return nothing
end

"""
    update_marker_position!(phaseinfo, tgtfile, reffile)

Converts `phaseinfo`'s strand1 and strand2's starting position in
terms of matrix rows of `X` to starting position in terms matrix
rows in `H`.
"""
function update_marker_position!(
    phaseinfo::Vector{HaplotypeMosaicPair},
    XtoH_idx::AbstractVector,
    )
    people = length(phaseinfo)

    @inbounds for j in 1:people
        # update strand1's starting position
        for (i, idx) in enumerate(phaseinfo[j].strand1.start)
            phaseinfo[j].strand1.start[i] = XtoH_idx[idx]
        end
        # update strand2's starting position
        for (i, idx) in enumerate(phaseinfo[j].strand2.start)
            phaseinfo[j].strand2.start[i] = XtoH_idx[idx]
        end
    end

    # update first starting position
    @inbounds for j in 1:people
        phaseinfo[j].strand1.start[1] = 1
        phaseinfo[j].strand2.start[1] = 1
    end

    return nothing
end

"""
    assign_snpscore(total_snps, typed_snp_scores, typed_index)

For each untyped SNP, average the nearest 2 typed SNP's quality score and
return a vector of quality scores for all SNPs, typed and untyped.

# Inputs
- `total_snps`: Total number of SNPs, typed and untyped
- `typed_snp_scores`: Vector of scores for each typed SNP
- `typed_index`: Typed SNP's indices
"""
function assign_snpscore(
    total_snps::Int,
    typed_snp_scores::AbstractVector,
    typed_index::AbstractVector
    )
    # copy typed SNPs' quality score into vector of complete SNPs
    complete_snpscore = Vector{eltype(typed_snp_scores)}(undef, total_snps)
    copyto!(@view(complete_snpscore[typed_index]), typed_snp_scores)
    println(complete_snpscore[1:20])

    # all untyped SNPs before first typed SNPs gets same quality score
    cur_range = 1:(typed_index[1] - 1)
    complete_snpscore[cur_range] .= typed_snp_scores[1]

    # loop through every segments of untyped SNPs
    for i in 2:length(typed_index)
        cur_range = (typed_index[i - 1] + 1):(typed_index[i] - 1)
        avg_score = (typed_snp_scores[i - 1] + typed_snp_scores[i]) / 2
        complete_snpscore[cur_range] .= avg_score
    end

    # last segment of untyped SNPs
    cur_range = (typed_index[end] + 1):total_snps
    complete_snpscore[cur_range] .= typed_snp_scores[end]

    println(complete_snpscore[1:20])
    return complete_snpscore
end
