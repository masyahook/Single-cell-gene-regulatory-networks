#!/bin/bash
#SBATCH --job-name="grnboost2_ctx"
#SBATCH --workdir=.
#SBATCH --output=./logs/grnboost2_ctx_%j.out
#SBATCH --error=./logs/grnboost2_ctx_%j.err
#SBATCH --cpus-per-task=16
#SBATCH --ntasks=1
#SBATCH --time=20:00:00


module load python/3.7.4

export PATH=/home/bsc08/bsc08890/.local/bin:/home/bsc08/bsc08890/bin:$PATH
export PYTHONPATH=/home/bsc08/bsc08890/.local/lib/python3.7/site-packages:$PYTHONPATH

##########################################
############# Input params ###############
##########################################

METHOD=$1
PATH2DATA=~/res/PilotWorkflow/data/Seurat/raw_data.tsv
DB_NAMES=~/data/SCENIC/hg38__refseq-r80__10kb_up_and_down_tss.mc9nr.feather
MOTIF_ANNOTATION=~/data/SCENIC/motifs-v9-nr.hgnc-m0.001-o0.0.tbl
OUTPUT=~/res/PilotWorkflow/data/$METHOD/raw_data_ctx.tsv
GRN_ADJ=~/res/PilotWorkflow/data/$METHOD/raw_data.tsv

##########################################
##########################################
##########################################

pyscenic ctx $GRN_ADJ $DB_NAMES --annotations_fname $MOTIF_ANNOTATION --expression_mtx_fname $PATH2DATA \
             --output $OUTPUT --transpose --num_workers 4


