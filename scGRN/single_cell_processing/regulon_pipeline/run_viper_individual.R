rm(list=ls())  # clear namespace
suppressPackageStartupMessages({
  library(Seurat)
  library(dplyr)
  library(future)
  library(ggplot2)
  library(optparse)
  library(dorothea)
  library(tibble)
  library(tidyr)
  library(reticulate)
})

pd <- import('pandas')

# save figures without messages
my_ggsave <- function(obj, filename){
  suppressMessages(ggsave(obj, filename = filename))
}

# deal with duplicate slashes
file_path = function(..., fsep = .Platform$file.sep){
  gsub("//", "/", file.path(..., fsep = fsep))
}

# prevent Rplots.pdf from being generated (turn off to visualize in RStudio Server)
pdf(NULL)

###################### INPUT

option_list = list(
  make_option(c("-p", "--pat"), type="character", help="Patient ID", metavar="character"),
  make_option(c("-m", "--meta_file"), type="character", help="Metadata file", metavar="character"),
  make_option(c("-o", "--outdir"), type="character", help="Output folder", metavar="character"),
  make_option(c('-r', '--regulon'), type='character', default='pyscenic', help='Regulons to use - either dorothea or pyscenic', metavar='character'),
  make_option(c('-q', '--quantile'), type='character', default='', help='Quantile threshold used when filtering network, using unfiltered network if not specified', metavar='character'),
  make_option(c("-c", "--pleiotropy_correction"), type="logical", default=T, help='Pleitropy correction?', metavar="T|F"),
  make_option(c('-n', '--num_proc'), type='integer', help='Number of processes run in parallel', default=6, metavar='integer'),
  make_option(c("-s", "--serialize"), type="logical", default=T, help="Save Seurat object", metavar="T|F"),
  make_option(c("-v", "--verbose"), type="logical", default=F, help="Verbose level", metavar="T|F")
)
opt_parser <- OptionParser(option_list=option_list, add_help_option = T)
opt <- parse_args(opt_parser)

# mandatory params
if (is.null(opt$pat) || opt$pat == ''){
  print_help(opt_parser)
  stop("No patient ID provided", call.=FALSE)
}
if (is.null(opt$meta_file) || opt$meta_file == ''){
  print_help(opt_parser)
  stop("No metadata file path provided", call.=FALSE)
}
if (is.null(opt$outdir) || opt$outdir == ''){
  print_help(opt_parser)
  stop("No output folder path provided", call.=FALSE)
}

# arbitrary params
if (opt$regulon == ''){
  opt$regulon = 'pyscenic'
}
if (is.na(opt$pleiotropy_correction)){
  opt$pleiotropy_correction = T
}
if (is.na(opt$num_proc)){
  opt$num_proc = 6
}
if (is.na(opt$serialize)){
  opt$serialize = T
}
if (is.na(opt$verbose)){
  opt$verbose = F
}

cat("\n\n")
cat("***********************************************\n")
cat("*** VIPER PROCESSING FOR INDIVIDUAL PATIENT ***\n")
cat("***********************************************\n\n")
cat("Outdir: ", opt$outdir, "\n")
cat("Patient: ", opt$pat, "\n")
cat("Metadata: ", opt$meta_file, "\n")
cat("Regulon type: ", opt$regulon, "\n")
cat("Network quantile threshold filter: ", opt$quantile, "\n")
cat("Apply pleiotropy correction: ", opt$pleiotropy_correction, "\n")
cat("Parallelized by: ", opt$num_proc, '\n')
cat("Serialize output: ", opt$serialize, "\n")
cat("Verbose: ", opt$verbose, "\n")

###################### LOAD DATA

# read metadata
meta <- read.table(opt$meta_file, header=T, sep="\t", stringsAsFactors = F)

# set up working directories
opt$outpat <- file_path(opt$outdir, opt$pat)
opt$outdat <- file_path(opt$outpat, "/data/Seurat/regulon")
opt$outfig <- file_path(opt$outpat, "/figs/Seurat/regulon")

# create working directories
dir.create(opt$outpat, recursive=T, showWarnings = F)
dir.create(opt$outdat, recursive=T, showWarnings = F)
dir.create(opt$outfig, recursive=T, showWarnings = F)

# delete all previously generated files
# invisible(file.remove(list.files(opt$outdat, full.names = T, recursive = T, pattern = sprintf('.*%s.*', opt$regulon))))
# invisible(file.remove(list.files(opt$outfig, full.names = T, recursive = T, pattern = sprintf('.*%s.*', opt$regulon))))

###################### INIT
cat("      - Init\n")

# getting DoRothEA
dorothea_regulon_human <- get(data("dorothea_hs", package = "dorothea"))

# getting dorothea regulons if chosen
if (opt$regulon == 'dorothea'){
  regulon <- dorothea_regulon_human %>%
    dplyr::filter(confidence %in% c("A","B","C"))
}

# load pyscenic regulons if chosen
if (opt$regulon == 'pyscenic' | opt$regulon == 'pyscenic_dorothea'){
  
  # setting up path to pyscenic regulons
  thresh <- 0.1
  pyscenic_regulon_dir <- file_path(opt$outpat, '/data/grnboost2/pickle')
  quantile_fmt = gsub('\\.', '_', opt$quantile)
  
  # loading pyscenic regulons 
  if (opt$quantile != ''){
    regulon <- pd$read_pickle(
      file_path(pyscenic_regulon_dir, sprintf('/raw_data_TF_ctx_filtered_%s.pickle', quantile_fmt))
      )
  } else {
    regulon <- pd$read_pickle(file_path(pyscenic_regulon_dir, '/raw_data_TF_ctx.pickle'))
  }
  
  # re-ordering columns
  regulon <- regulon[,c('TF', 'importance', 'target', 'rho')]
  colnames(regulon) <- c('tf', 'importance', 'target', 'rho')
  
  if (opt$regulon == 'pyscenic') {
    # defining activated/inactivated pyscenic regulons
    regulon$mor <- regulon$rho
    regulon$mor[regulon$mor > thresh] <- 1
    regulon$mor[regulon$mor < -thresh] <- -1
    regulon <- regulon[regulon$mor %in% c(-1, 1),] %>% as_tibble()
  } else if (opt$regulon == 'pyscenic_dorothea') {
    # getting only overlapping regulons between pyscenic and dorothea
    regulon <- regulon %>%
      merge(dorothea_regulon_human, by.x=c('tf', 'target'), by.y=c('tf', 'target')) %>%
      as_tibble()
  }
}

# loading scRNA-seq matrix
load(file_path(opt$outpat, "/data/Seurat/seurat_object.RData"))

###################### VIPER BASED ON DOROTHEA REGULONS

cat("      - Running VIPER\n")

# running viper
sobj <- run_viper(sobj, regulon,
                  options = list(method = "scale", minsize = 4, 
                                 pleiotropy = opt$pleiotropy_correction, 
                                 eset.filter = FALSE, 
                                 cores = opt$num_proc, verbose = FALSE),
)

# saving results
if (opt$regulon == 'pyscenic' | opt$regulon == 'pyscenic_dorothea'){
  sobj <- RenameAssays(object = sobj, 'dorothea'=opt$regulon)
}
DefaultAssay(object = sobj) <- opt$regulon

###################### SCALE DATA
cat("      - Scaling\n")

sobj <- ScaleData(object = sobj, verbose = F)

###################### DIM REDUCTION
cat("      - Dimensionality reduction\n")

## PCA
sobj <- RunPCA(object = sobj, features = rownames(sobj), verbose = F)
# loadings
sobj@misc$plots[[sprintf('%s_pca_loadings', opt$regulon)]] <- VizDimLoadings(sobj, dims = 1:4, reduction = "pca")
my_ggsave(sobj@misc$plots[[sprintf('%s_pca_loadings', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_pca_loadings.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_pca_loadings', opt$regulon)]]
# elbow
sobj@misc$plots[[sprintf('%s_pca_elbow', opt$regulon)]] <- ElbowPlot(sobj, ndims = 40)
my_ggsave(sobj@misc$plots[[sprintf('%s_pca_elbow', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_pca_elbow.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_pca_elbow', opt$regulon)]]
# PCA scatter plot and PC heatmap plot
sobj@misc$plots[[sprintf('%s_pca_main', opt$regulon)]] <- DimPlot(object = sobj, reduction = "pca")
my_ggsave(sobj@misc$plots[[sprintf('%s_pca_main', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_pca_main.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_pca_main', opt$regulon)]]
sobj@misc$plots[[sprintf('%s_pca_heatmap', opt$regulon)]] <- DimHeatmap(sobj, dims = 1:4, ncol=2, nfeatures = 30, cells = 1000, balanced = TRUE, fast = F)
my_ggsave(sobj@misc$plots[[sprintf('%s_pca_heatmap', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_pca_heatmap.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_pca_heatmap', opt$regulon)]]

## T-SNE
sobj <- RunTSNE(object = sobj, dims = 1:10, verbose = F)
sobj@misc$plots[[sprintf('%s_tsne_main', opt$regulon)]] <- DimPlot(object = sobj, reduction = "tsne")
my_ggsave(sobj@misc$plots[[sprintf('%s_tsne_main', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_tsne_main.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_tsne_main', opt$regulon)]]

## U-MAP
sobj <- RunUMAP(object = sobj, dims=1:10, verbose = F, umap.method = "uwot", metric = "cosine")
sobj@misc$plots[[sprintf('%s_umap_main', opt$regulon)]] <- DimPlot(object = sobj, reduction = "umap")
my_ggsave(sobj@misc$plots[[sprintf('%s_umap_main', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_umap_main.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_umap_main', opt$regulon)]]

###################### FIND CLUSTERS
cat("      - Find clusters\n")

sobj <- FindNeighbors(sobj, dims = 1:10, verbose = FALSE)
sobj <- FindClusters(sobj, resolution = 0.5, verbose = FALSE)

sobj@misc$plots[[sprintf('%s_pca_clusters', opt$regulon)]] <- DimPlot(object = sobj, reduction = "pca")
my_ggsave(sobj@misc$plots[[sprintf('%s_pca_clusters', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_pca_clusters.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_pca_clusters', opt$regulon)]]
sobj@misc$plots[[sprintf('%s_tsne_clusters', opt$regulon)]] <- DimPlot(object = sobj, reduction = "tsne")
my_ggsave(sobj@misc$plots[[sprintf('%s_tsne_clusters', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_tsne_clusters.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_tsne_clusters', opt$regulon)]]
sobj@misc$plots[[sprintf('%s_umap_clusters', opt$regulon)]] <- DimPlot(object = sobj, reduction = "umap")
my_ggsave(sobj@misc$plots[[sprintf('%s_umap_clusters', opt$regulon)]], filename = file_path(opt$outfig, sprintf("/%s_umap_clusters.png", opt$regulon)))
sobj@misc$plots[[sprintf('%s_umap_clusters', opt$regulon)]]

###################### GENE MARKERS
cat("      - Gene markers by cluster\n")

# find markers for every cluster compared to all remaining cells, report only the positive ones
sobj.markers <- FindAllMarkers(sobj, only.pos = TRUE, min.pct = 0.25, logfc.threshold = 0.25, verbose = opt$verbose)
# top-2 markers per cluster, print them
sobj.markers %>% group_by(cluster) %>% top_n(n = 2, wt = "avg_log2FC")
sobj@misc$markers <- sobj.markers
# plot top-10 markers per cluster
top10 <- sobj.markers %>% group_by(cluster) %>% top_n(n = 10, wt = "avg_log2FC")
sobj@misc$plots$markers <- DoHeatmap(sobj, features = top10$gene) + NoLegend()
my_ggsave(sobj@misc$plots$markers, filename = file_path(opt$outfig, "markers.png"))
sobj@misc$plots$markers

###################### FINISH
cat("      - Saving\n")

if (opt$serialize == T) save(sobj, file=file_path(opt$outdat, sprintf("/%s_seurat_object.RData", opt$regulon)))

write.table(sobj@assays[[opt$regulon]]@data, file=file_path(opt$outdat, sprintf("/%s_data.tsv", opt$regulon)), sep="\t", row.names=T, col.names=colnames(sobj@assays[[opt$regulon]]@data), quote=F)
write.table(sobj@assays[[opt$regulon]]@scale.data, file=file_path(opt$outdat, sprintf("/%s_scaled_data.tsv", opt$regulon)), sep="\t", row.names=T, col.names=colnames(sobj@assays[[opt$regulon]]@scale.data), quote=F)

# cell type-specific
cell_types <- unique(sobj[['cell_type']][['cell_type']])
for (i in 1:length(cell_types))
{
  type <- cell_types[i]
  cell_type_sobj <- subset(x=sobj, subset = cell_type == type)
  write.table(sobj@assays[[opt$regulon]]@data, file=file_path(opt$outdat, sprintf("/%s_data_%s.tsv", opt$regulon, type)), sep="\t", row.names=T, col.names=colnames(sobj@assays[[opt$regulon]]@data), quote=F)
}

cat("\n\n[finished]\n\n")
