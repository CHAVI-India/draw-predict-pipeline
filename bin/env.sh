export BASE_DIR=./data
export RAW_DATA_DIR=$BASE_DIR/raw
export nnUNet_raw=$BASE_DIR/nnUNet_raw
export nnUNet_preprocessed=$BASE_DIR/nnUNet_preprocessed
export nnUNet_results=$BASE_DIR/nnUNet_results
# Point nnUNet to custom DRAW trainers in the pipeline repo
export nnUNet_extTrainer="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/draw/nnunet_trainers"
