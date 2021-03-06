# Install and load required packages

# Bioconductor Packages

if (!"Biostrings" %in% installed.packages()) {
    source("http://bioconductor.org/biocLite.R")
    biocLite("Biostrings")
}

library("Biostrings")
# CRAN packages

if (!"dplyr" %in% installed.packages()) install.packages("dplyr")
library("dplyr")
if (!"taxize" %in% installed.packages()) install.packages("taxize")
library("taxize")
if (!"devtools" %in% installed.packages()) install.packages("devtools")
library("devtools")
if (!"rBLAST" %in% installed.packages()) install_github("mhahsler/rBLAST")
library("rBLAST")





### Function for determining if original greengenes taxonomy is incomplete.
# Incomplete is not assigned at specified taxonomic level.
# Returns boolean TRUE if taxonomy is incomplete.

is_taxonomy_incomplete <- function(taxonomy, level = "spcs") {
    str_splt <- strsplit(taxonomy, ";")
    switch(level,
            spcs = {
            # Species level
            return(length(str_splt[[1]]) < 7 || length(strsplit(str_splt[[1]][7], "__")[[1]]) < 2)
            },
            gen = {
            # Genus level
            return(length(str_splt[[1]]) < 6 || length(strsplit(str_splt[[1]][6], "__")[[1]]) < 2)
            },
            fam = {
            # Family
            return(length(str_splt[[1]]) < 5 || length(strsplit(str_splt[[1]][5], "__")[[1]]) < 2)
            })
}





### Function for blasting sequences against microbial refseq 16s database and returning the taxonomy from NCBI's taxonomy database.
# Orders results by bits and percent of identity. Then chooses the first match with identity percent.
# Returns vector of size 3 including:
# 1) bool if % indentity is at least given number, def. 97 and bits >= 100;
# 2) float of blast result's % identity;
# 3) taxonomy in ncbi's format.

blast_n_get_ncbi_tax <- function(seq, perc_ident = 97, min_E = 1e-40, microbial_database) {
    # Blasts sequence and return a table of results. Orders it by BITS from greater value.
    blast_result_table <- arrange(predict(microbial_database, seq), E)
    # variable to store if we found a sequence with at least percent id value.
    min_percent_found <- FALSE
    # For each row of the results table.
    for (row in 1:nrow(blast_result_table)) {
        # if current result has a percent id of at least given value.
        if (blast_result_table[row, ]$Perc.Ident >= perc_ident) {
            # set to true as we found a seq with at least given percent of id.
            min_percent_found <- TRUE
            # make current row the blast result.
            blast_result <- blast_result_table[row,]
            break
        }
    }
    # if we didnt found a seq with at least given perc. id.
    if (min_percent_found == FALSE) {
        # result with higher bits value is chosen.
        blast_result <- blast_result_table[1,]
    }
    # Return our results vector. 
    return(c(
           ((blast_result["Perc.Ident"] >= perc_ident) & (blast_result["E"] <= min_E)),
           (blast_result["Perc.Ident"]),
           (blast_result["Bits"]),
           # Grab taxonomy from ncbi taxonomy server
           (classification(genbank2uid(id = blast_result["SubjectID"][1, 1]),db = "ncbi"))))
}





### Function for parsing the NCBI's taxonomy into greengenes format.
# Input is NCBI's taxonomy as a nested list containing information about each level of the classification.
# Returns string of taxonomy in greengenes format.

parse_ncbi_to_gg <- function(ncbi_tax) {
    return(sprintf("k__%s; p__%s; c__%s; o__%s; f__%s; g__%s; s__%s",
    # Kingdom
           filter(ncbi_tax[[1]], rank == "superkingdom")[1, 1],
    # Phylum
           filter(ncbi_tax[[1]], rank == "phylum")[1, 1],
    # Class
           filter(ncbi_tax[[1]], rank == "class")[1, 1],
    # Order
           filter(ncbi_tax[[1]], rank == "order")[1, 1],
    # Family
           filter(ncbi_tax[[1]], rank == "family")[1, 1],
    # Genus
           filter(ncbi_tax[[1]], rank == "genus")[1, 1],
    # Species
           strsplit(filter(ncbi_tax[[1]], rank == "species")[1, 1], " ")[[1]][2]))
}




### Funtion for downloading the required database.
get_database <- function(phyl_group = "bacteria", path = ".") {

    # If database folder does not exist
    if (!file.exists(paste0(path, "/16SMicrobialDB/16SMicrobial.nhr")) & phyl_group == "bacteria") {
        # Download database.
        print("Dowloading database")
        download.file("ftp://ftp.ncbi.nlm.nih.gov/blast/db/16SMicrobial.tar.gz", paste0(path, "/16SMicrobial.tar.gz"), mode = 'wb')
        # Extract reference database.
        untar(paste0(path, "/16SMicrobial.tar.gz"), exdir = paste0(path, "/16SMicrobialDB"))
    }
    else if (!file.exists(paste0(path, "/fungi.ITS.fna/fungi.ITS.fna.nhr")) & phyl_group == "fungi") {
        print("Dowloading database")
        download.file("ftp://ftp.ncbi.nlm.nih.gov/refseq/TargetedLoci/Fungi/fungi.ITS.gbff.gz", paste0(path, "/16SMicrobial.tar.gz"), mode = 'wb')
        untar(paste0(path, "/16SMicrobial.tar.gz"), exdir = paste0(path, "16SMicrobialDB"))
        # falta blastear
    }

    # return database
    return(blast(db = paste0(path, "/16SMicrobialDB/16SMicrobial")))
}





### Function for updating a taxonomy table generated by QIIME 2 (taxonomy.tsv).
#The updated table can be joined to the corresponding BIOM file to perform the rest of the analyses of the QIIME2 pipeline.
# Inputs are:
#   1) taxonomy_table: a taxonomy table in tsv format is dataframe type.
#   2) data_fasta: fasta file for all the otus in taxonomy table (with the same otu_ids).
#   3) level: string describing the desired level of analysis deafault:"spcs"; also: "gen" or "fam".
#   4) phyl_group: string describing the analysed group. deafault: "bacteria"; also: "fungi".
#   5) update_all: bool. Indicates if the user wants to reassign all the otus or only the otus with incomplete taxonomies. Default: FALSE
# Returns a dataframe with the updated taxonomy using the same layout as the original input.
# Dataframe can be writen to tsv format to use with QIIME2.

update_taxonomy_refseq <- function(taxonomy_table, data_fasta, microbial_database, level = "spcs", phyl_group = "bacteria", update_all = FALSE) {
    taxonomy_table$Taxon <- as.character(taxonomy_table$Taxon)
    #taxonomy_table <- as.data.frame(apply(taxonomy_table, 2, as.character), stringsAsFactors = FALSE)
    #taxonomy_table$Feature.ID <- as.character(taxonomy_table$Feature.ID)
    #taxonomy_table <- as.data.frame(taxonomy_table, stringsAsFactors = FALSE)
    # selecting working percent identity 
    switch(level,
            spcs = {
    # Species level
    percent = 97
    },
            gen = {
    # Genus level
    percent = 95
    },
            fam = {
    # Family
    percent = 90
    })

    # Iterate over taxonomy table
    for (otu_entry in 1:nrow(taxonomy_table)) {
        print(sprintf("OTU: %s / %s", otu_entry, nrow(taxonomy_table)))
        #print("otu_entry")
        #print(otu_entry)
        # grab taxonomy for each entry. Is a string?!!! ######## CHECK ######
        current_taxonomy <- as.character((taxonomy_table[otu_entry,] %>% select(Taxon))[1, 1])
        # If update_all TRUE or if not If current taxonomy is incomplete.
        if (update_all | is_taxonomy_incomplete(current_taxonomy)) {
            tryCatch({
                    # get otu_id ######## CHECK ######
                    current_id <- select(taxonomy_table[otu_entry,], Feature.ID)[1, 1]
                    # get otu sequence from fasta file. ######## CHECK ######
                    current_sequence <- data_fasta[data_fasta@ranges@NAMES == current_id]
                    # get new taxonomy
                    new_ncbi_taxonomy <- blast_n_get_ncbi_tax(seq = current_sequence, perc_ident = percent, min_E = 1e-40, microbial_database)
                    # If ident. perc is above specified.
                    if (new_ncbi_taxonomy[[1]]) {
                        # Replace taxonomy and ident. perc.
                        taxonomy_table <- taxonomy_table %>% mutate(Confidence = replace(Confidence, which(Feature.ID == current_id), (new_ncbi_taxonomy[2])))
                        taxonomy_table <- taxonomy_table %>% mutate(Taxon = replace(Taxon, which(Feature.ID == current_id), parse_ncbi_to_gg(new_ncbi_taxonomy[4])))
                        }
                    },
                    error = function(e) {
                        #message("Here's the original error message:\n")
                        #message(e)
                    },
                    warning = function(e) {
                        #message("Here's the original error message:\n")
                        #message(e)
                    }
            )            
        }
        # Wait 0.2 seconds to prevent ncbi's server to explode.
        Sys.sleep(0.2)
    }

    taxonomy_table <- apply(taxonomy_table, 2, as.character)

    return(taxonomy_table)
}


####

# To do:
# fungi selection
# off-line taxonomy
